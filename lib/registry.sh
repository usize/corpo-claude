#!/usr/bin/env bash
# lib/registry.sh — Registry management and GitHub API caching

# Registry tiers (searched in order):
#   1. Local  — $CORPO_ROOT/skills/
#   2. Default remote — anthropics/skills (always present)
#   3. User-added remotes — stored in $CORPO_DATA_DIR/registries.json

REGISTRIES_FILE="$CORPO_DATA_DIR/registries.json"
DEFAULT_REMOTE="anthropics/skills"
CACHE_TTL=3600  # 1 hour in seconds

# ── Registry CRUD ─────────────────────────────────────────

# Ensure registries.json exists
_ensure_registries_file() {
  ensure_data_dir
  if [[ ! -f "$REGISTRIES_FILE" ]]; then
    echo '[]' > "$REGISTRIES_FILE"
  fi
}

# List all registries (local + default + user-added)
registry_list() {
  _ensure_registries_file

  gum style --bold --foreground 39 "Skill Registries"
  echo ""
  gum style "  local       $CORPO_ROOT/skills/"

  gum style "  default     $DEFAULT_REMOTE"

  local user_registries
  user_registries="$(jq -r '.[]' "$REGISTRIES_FILE")"
  if [[ -n "$user_registries" ]]; then
    while IFS= read -r repo; do
      gum style "  added       $repo"
    done <<< "$user_registries"
  fi
}

# Add a user registry (owner/repo format)
registry_add() {
  local repo="$1"

  if [[ -z "$repo" ]]; then
    error "Usage: corpo-claude registry add <owner/repo>"
    return 1
  fi

  # Validate format
  if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    error "Invalid registry format. Expected: owner/repo"
    return 1
  fi

  if [[ "$repo" == "$DEFAULT_REMOTE" ]]; then
    warn "$DEFAULT_REMOTE is already included as the default registry."
    return 0
  fi

  _ensure_registries_file

  # Check if already added
  if jq -e --arg repo "$repo" '. | index($repo)' "$REGISTRIES_FILE" &>/dev/null; then
    warn "$repo is already registered."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg repo "$repo" '. += [$repo]' "$REGISTRIES_FILE" > "$tmp" && mv "$tmp" "$REGISTRIES_FILE"
  success "Registry added: $repo"
}

# Remove a user registry
registry_remove() {
  local repo="$1"

  if [[ -z "$repo" ]]; then
    error "Usage: corpo-claude registry remove <owner/repo>"
    return 1
  fi

  if [[ "$repo" == "$DEFAULT_REMOTE" ]]; then
    error "Cannot remove the default registry ($DEFAULT_REMOTE)."
    return 1
  fi

  _ensure_registries_file

  if ! jq -e --arg repo "$repo" '. | index($repo)' "$REGISTRIES_FILE" &>/dev/null; then
    warn "$repo is not registered."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg repo "$repo" '. | map(select(. != $repo))' "$REGISTRIES_FILE" > "$tmp" && mv "$tmp" "$REGISTRIES_FILE"
  success "Registry removed: $repo"
}

# ── Registry command router ───────────────────────────────

cmd_registry() {
  if [[ $# -eq 0 ]]; then
    registry_list
    return 0
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    list)
      registry_list
      ;;
    add)
      registry_add "${1:-}"
      ;;
    remove)
      registry_remove "${1:-}"
      ;;
    *)
      error "Unknown registry subcommand: $subcmd"
      echo "Usage: corpo-claude registry [list|add|remove] [args]"
      return 1
      ;;
  esac
}

# ── Cache layer ───────────────────────────────────────────

# Returns the cache file path for a given owner/repo
_cache_path() {
  local repo="$1"
  local safe_name="${repo//\//__}"
  echo "$CORPO_DATA_DIR/cache/${safe_name}.json"
}

# Check if cache is fresh (< TTL seconds old)
_cache_is_fresh() {
  local cache_file="$1"

  if [[ ! -f "$cache_file" ]]; then
    return 1
  fi

  local now file_age age_seconds
  now="$(date +%s)"

  # macOS stat
  if stat -f %m "$cache_file" &>/dev/null; then
    file_age="$(stat -f %m "$cache_file")"
  else
    # Linux stat
    file_age="$(stat -c %Y "$cache_file")"
  fi

  age_seconds=$((now - file_age))
  [[ "$age_seconds" -lt "$CACHE_TTL" ]]
}

# ── Remote skill index ────────────────────────────────────

# Fetch the skill index for a remote registry.
# Returns JSON array: [{"name": "...", "description": "...", "registry": "..."}]
fetch_remote_skill_index() {
  local repo="$1"
  local refresh="${2:-false}"
  local cache_file
  cache_file="$(_cache_path "$repo")"

  ensure_data_dir

  # Use cache if fresh and not forcing refresh
  if [[ "$refresh" != "true" ]] && _cache_is_fresh "$cache_file"; then
    cat "$cache_file"
    return 0
  fi

  # Fetch repo tree via gh
  local tree_json
  tree_json="$(gh api "repos/$repo/git/trees/main?recursive=1" 2>/dev/null)" || {
    # Try 'master' branch as fallback
    tree_json="$(gh api "repos/$repo/git/trees/master?recursive=1" 2>/dev/null)" || {
      warn "Failed to fetch tree for $repo"
      # Return empty array on failure
      echo '[]'
      return 1
    }
  }

  # Find all skills/*/SKILL.md paths
  local skill_paths
  skill_paths="$(echo "$tree_json" | jq -r '.tree[] | select(.path | test("^skills/[^/]+/SKILL\\.md$")) | .path')"

  if [[ -z "$skill_paths" ]]; then
    echo '[]' > "$cache_file"
    echo '[]'
    return 0
  fi

  local skills_json="[]"

  while IFS= read -r skill_path; do
    [[ -z "$skill_path" ]] && continue

    # Extract skill name from path (skills/<name>/SKILL.md)
    local skill_name
    skill_name="$(echo "$skill_path" | sed 's|^skills/||; s|/SKILL\.md$||')"

    # Fetch the SKILL.md content to extract frontmatter description
    local content
    content="$(gh api "repos/$repo/contents/$skill_path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || continue

    # Extract description from YAML frontmatter (between --- markers)
    local description=""
    if echo "$content" | head -1 | grep -q '^---'; then
      description="$(echo "$content" | sed -n '/^---$/,/^---$/p' | grep -i '^description:' | sed 's/^[Dd]escription:[[:space:]]*//' | head -1)"
    fi

    # If no frontmatter description, use first non-empty line after frontmatter as fallback
    if [[ -z "$description" ]]; then
      description="$(echo "$content" | sed '1,/^---$/d' | sed '1,/^---$/d' | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^#*[[:space:]]*//')"
    fi

    skills_json="$(echo "$skills_json" | jq --arg name "$skill_name" --arg desc "$description" --arg reg "$repo" \
      '. += [{"name": $name, "description": $desc, "registry": $reg}]')"
  done <<< "$skill_paths"

  echo "$skills_json" > "$cache_file"
  echo "$skills_json"
}

# ── Local skill index ─────────────────────────────────────

# Scan $CORPO_ROOT/skills/ for bundled skills.
# Returns JSON array: [{"name": "...", "description": "...", "registry": "local"}]
fetch_local_skill_index() {
  local skills_dir="$CORPO_ROOT/skills"
  local skills_json="[]"

  if [[ ! -d "$skills_dir" ]]; then
    echo '[]'
    return 0
  fi

  for skill_dir in "$skills_dir"/*/; do
    [[ -d "$skill_dir" ]] || continue
    local skill_md="$skill_dir/SKILL.md"
    [[ -f "$skill_md" ]] || continue

    local skill_name
    skill_name="$(basename "$skill_dir")"

    # Extract description from YAML frontmatter
    local description=""
    if head -1 "$skill_md" | grep -q '^---'; then
      description="$(sed -n '/^---$/,/^---$/p' "$skill_md" | grep -i '^description:' | sed 's/^[Dd]escription:[[:space:]]*//' | head -1)"
    fi

    if [[ -z "$description" ]]; then
      description="$(sed '1,/^---$/d' "$skill_md" | sed '1,/^---$/d' | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^#*[[:space:]]*//')"
    fi

    skills_json="$(echo "$skills_json" | jq --arg name "$skill_name" --arg desc "$description" \
      '. += [{"name": $name, "description": $desc, "registry": "local"}]')"
  done

  echo "$skills_json"
}

# ── Combined index across all registries ──────────────────

# Returns merged JSON array from all registry tiers.
fetch_all_skill_indexes() {
  local refresh="${1:-false}"
  local combined="[]"

  # Tier 1: Local
  local local_skills
  local_skills="$(fetch_local_skill_index)"
  combined="$(echo "$combined" "$local_skills" | jq -s '.[0] + .[1]')"

  # Tier 2: Default remote
  if check_skills_dependencies 2>/dev/null; then
    local default_skills
    default_skills="$(fetch_remote_skill_index "$DEFAULT_REMOTE" "$refresh")"
    combined="$(echo "$combined" "$default_skills" | jq -s '.[0] + .[1]')"

    # Tier 3: User-added remotes
    _ensure_registries_file
    local user_registries
    user_registries="$(jq -r '.[]' "$REGISTRIES_FILE")"
    if [[ -n "$user_registries" ]]; then
      while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local remote_skills
        remote_skills="$(fetch_remote_skill_index "$repo" "$refresh")"
        combined="$(echo "$combined" "$remote_skills" | jq -s '.[0] + .[1]')"
      done <<< "$user_registries"
    fi
  fi

  echo "$combined"
}

# ── Find a skill across all registries ────────────────────

# Search for a skill by name across all registries.
# Returns first match (respecting tier order).
# Output: JSON object {"name", "description", "registry"} or empty
find_skill() {
  local skill_name="$1"
  local refresh="${2:-false}"

  # Tier 1: Check local first
  local local_skills
  local_skills="$(fetch_local_skill_index)"
  local match
  match="$(echo "$local_skills" | jq --arg name "$skill_name" '[.[] | select(.name == $name)] | first // empty')"
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi

  # Need gh for remote registries
  if ! check_skills_dependencies 2>/dev/null; then
    return 1
  fi

  # Tier 2: Default remote
  local default_skills
  default_skills="$(fetch_remote_skill_index "$DEFAULT_REMOTE" "$refresh")"
  match="$(echo "$default_skills" | jq --arg name "$skill_name" '[.[] | select(.name == $name)] | first // empty')"
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi

  # Tier 3: User-added remotes
  _ensure_registries_file
  local user_registries
  user_registries="$(jq -r '.[]' "$REGISTRIES_FILE")"
  if [[ -n "$user_registries" ]]; then
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      local remote_skills
      remote_skills="$(fetch_remote_skill_index "$repo" "$refresh")"
      match="$(echo "$remote_skills" | jq --arg name "$skill_name" '[.[] | select(.name == $name)] | first // empty')"
      if [[ -n "$match" ]]; then
        echo "$match"
        return 0
      fi
    done <<< "$user_registries"
  fi

  return 1
}
