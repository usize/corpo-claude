#!/usr/bin/env bash
# lib/registry.sh — Registry management and GitHub API caching
#
# A registry is any repo (including corpo-claude itself) that contains
# skills/ and/or profiles/ directories following this structure:
#
#   skills/<name>/SKILL.md         — skill manifest
#   profiles/<name>/profile.yaml   — profile manifest
#
# Registry tiers (searched in order):
#   1. Local  — $CORPO_ROOT (corpo-claude repo itself)
#   2. Default remote — anthropics/skills (always present)
#   3. User-added remotes — stored in $CORPO_DATA_DIR/registries.json

REGISTRIES_FILE="$CORPO_DATA_DIR/registries.json"
DEFAULT_REMOTE="anthropics/skills"
CACHE_TTL=3600  # 1 hour in seconds

# ── Registry CRUD ─────────────────────────────────────────

_ensure_registries_file() {
  ensure_data_dir
  if [[ ! -f "$REGISTRIES_FILE" ]]; then
    echo '[]' > "$REGISTRIES_FILE"
  fi
}

registry_list() {
  _ensure_registries_file

  gum style --bold --foreground 39 "Registries"
  echo ""
  gum style "  local       $CORPO_ROOT"
  gum style "  default     $DEFAULT_REMOTE"

  local user_registries
  user_registries="$(jq -r '.[]' "$REGISTRIES_FILE")"
  if [[ -n "$user_registries" ]]; then
    while IFS= read -r repo; do
      gum style "  added       $repo"
    done <<< "$user_registries"
  fi
}

registry_add() {
  local repo="$1"

  if [[ -z "$repo" ]]; then
    error "Usage: corpo-claude registry add <owner/repo>"
    return 1
  fi

  if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    error "Invalid registry format. Expected: owner/repo"
    return 1
  fi

  if [[ "$repo" == "$DEFAULT_REMOTE" ]]; then
    warn "$DEFAULT_REMOTE is already included as the default registry."
    return 0
  fi

  _ensure_registries_file

  if jq -e --arg repo "$repo" '. | index($repo)' "$REGISTRIES_FILE" &>/dev/null; then
    warn "$repo is already registered."
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  jq --arg repo "$repo" '. += [$repo]' "$REGISTRIES_FILE" > "$tmp" && mv "$tmp" "$REGISTRIES_FILE"
  success "Registry added: $repo"
}

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

cmd_registry() {
  if [[ $# -eq 0 ]]; then
    registry_list
    return 0
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    list)   registry_list ;;
    add)    registry_add "${1:-}" ;;
    remove) registry_remove "${1:-}" ;;
    *)
      error "Unknown registry subcommand: $subcmd"
      echo "Usage: corpo-claude registry [list|add|remove] [args]"
      return 1
      ;;
  esac
}

# ── Cache layer ───────────────────────────────────────────

_cache_path() {
  local repo="$1" kind="$2"  # kind: "skills" or "profiles"
  local safe_name="${repo//\//__}"
  echo "$CORPO_DATA_DIR/cache/${safe_name}_${kind}.json"
}

_cache_is_fresh() {
  local cache_file="$1"
  [[ -f "$cache_file" ]] || return 1

  local now file_age age_seconds
  now="$(date +%s)"

  if stat -f %m "$cache_file" &>/dev/null; then
    file_age="$(stat -f %m "$cache_file")"
  else
    file_age="$(stat -c %Y "$cache_file")"
  fi

  age_seconds=$((now - file_age))
  [[ "$age_seconds" -lt "$CACHE_TTL" ]]
}

# ── Remote repo tree (shared) ────────────────────────────

# Fetch and cache the full repo tree. Returns raw tree JSON.
_fetch_repo_tree() {
  local repo="$1"
  local tree_json

  tree_json="$(gh api "repos/$repo/git/trees/main?recursive=1" 2>/dev/null)" || {
    tree_json="$(gh api "repos/$repo/git/trees/master?recursive=1" 2>/dev/null)" || {
      warn "Failed to fetch tree for $repo"
      return 1
    }
  }

  echo "$tree_json"
}

# ── Description extraction ────────────────────────────────

# Extract description from a SKILL.md or profile.yaml content string.
# For SKILL.md: looks for YAML frontmatter description field, falls back to first heading.
# For profile.yaml: looks for top-level description field.
_extract_description() {
  local content="$1"
  local file_type="$2"  # "skill" or "profile"

  if [[ "$file_type" == "profile" ]]; then
    echo "$content" | grep -i '^description:' | sed 's/^[Dd]escription:[[:space:]]*//' | head -1
    return
  fi

  # Skill: check YAML frontmatter
  local description=""
  if echo "$content" | head -1 | grep -q '^---'; then
    description="$(echo "$content" | sed -n '/^---$/,/^---$/p' | grep -i '^description:' | sed 's/^[Dd]escription:[[:space:]]*//' | head -1)"
  fi

  if [[ -z "$description" ]]; then
    description="$(echo "$content" | sed '1,/^---$/d' | sed '1,/^---$/d' | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^#*[[:space:]]*//')"
  fi

  echo "$description"
}

# ── Remote skill index ────────────────────────────────────

fetch_remote_skill_index() {
  local repo="$1"
  local refresh="${2:-false}"
  local cache_file
  cache_file="$(_cache_path "$repo" "skills")"

  ensure_data_dir

  if [[ "$refresh" != "true" ]] && _cache_is_fresh "$cache_file"; then
    cat "$cache_file"
    return 0
  fi

  local tree_json
  tree_json="$(_fetch_repo_tree "$repo")" || {
    echo '[]'
    return 1
  }

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

    local skill_name
    skill_name="$(echo "$skill_path" | sed 's|^skills/||; s|/SKILL\.md$||')"

    local content
    content="$(gh api "repos/$repo/contents/$skill_path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || continue

    local description
    description="$(_extract_description "$content" "skill")"

    skills_json="$(echo "$skills_json" | jq --arg name "$skill_name" --arg desc "$description" --arg reg "$repo" \
      '. += [{"name": $name, "description": $desc, "registry": $reg, "type": "skill"}]')"
  done <<< "$skill_paths"

  echo "$skills_json" > "$cache_file"
  echo "$skills_json"
}

# ── Remote profile index ──────────────────────────────────

fetch_remote_profile_index() {
  local repo="$1"
  local refresh="${2:-false}"
  local cache_file
  cache_file="$(_cache_path "$repo" "profiles")"

  ensure_data_dir

  if [[ "$refresh" != "true" ]] && _cache_is_fresh "$cache_file"; then
    cat "$cache_file"
    return 0
  fi

  local tree_json
  tree_json="$(_fetch_repo_tree "$repo")" || {
    echo '[]'
    return 1
  }

  # Find all profiles/*/profile.yaml paths
  local profile_paths
  profile_paths="$(echo "$tree_json" | jq -r '.tree[] | select(.path | test("^profiles/[^/]+/profile\\.ya?ml$")) | .path')"

  if [[ -z "$profile_paths" ]]; then
    echo '[]' > "$cache_file"
    echo '[]'
    return 0
  fi

  local profiles_json="[]"

  while IFS= read -r profile_path; do
    [[ -z "$profile_path" ]] && continue

    local profile_name
    profile_name="$(echo "$profile_path" | sed 's|^profiles/||; s|/profile\.ya\{0,1\}ml$||')"

    local content
    content="$(gh api "repos/$repo/contents/$profile_path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || continue

    local description
    description="$(_extract_description "$content" "profile")"

    profiles_json="$(echo "$profiles_json" | jq --arg name "$profile_name" --arg desc "$description" --arg reg "$repo" \
      '. += [{"name": $name, "description": $desc, "registry": $reg, "type": "profile"}]')"
  done <<< "$profile_paths"

  echo "$profiles_json" > "$cache_file"
  echo "$profiles_json"
}

# ── Local indexes ─────────────────────────────────────────

fetch_local_skill_index() {
  local skills_dir="$CORPO_ROOT/skills"
  local skills_json="[]"

  [[ -d "$skills_dir" ]] || { echo '[]'; return 0; }

  for skill_dir in "$skills_dir"/*/; do
    [[ -d "$skill_dir" ]] || continue
    local skill_md="$skill_dir/SKILL.md"
    [[ -f "$skill_md" ]] || continue

    local skill_name
    skill_name="$(basename "$skill_dir")"

    local description
    description="$(_extract_description "$(cat "$skill_md")" "skill")"

    skills_json="$(echo "$skills_json" | jq --arg name "$skill_name" --arg desc "$description" \
      '. += [{"name": $name, "description": $desc, "registry": "local", "type": "skill"}]')"
  done

  echo "$skills_json"
}

fetch_local_profile_index() {
  local profiles_dir="$CORPO_ROOT/profiles"
  local profiles_json="[]"

  [[ -d "$profiles_dir" ]] || { echo '[]'; return 0; }

  for profile_dir in "$profiles_dir"/*/; do
    [[ -d "$profile_dir" ]] || continue
    local profile_yaml=""
    for ext in yaml yml; do
      if [[ -f "$profile_dir/profile.$ext" ]]; then
        profile_yaml="$profile_dir/profile.$ext"
        break
      fi
    done
    [[ -n "$profile_yaml" ]] || continue

    local profile_name
    profile_name="$(basename "$profile_dir")"

    local description
    description="$(_extract_description "$(cat "$profile_yaml")" "profile")"

    profiles_json="$(echo "$profiles_json" | jq --arg name "$profile_name" --arg desc "$description" \
      '. += [{"name": $name, "description": $desc, "registry": "local", "type": "profile"}]')"
  done

  echo "$profiles_json"
}

# ── Combined indexes ─────────────────────────────────────

# Fetch all skills from all registry tiers.
fetch_all_skill_indexes() {
  local refresh="${1:-false}"
  local combined="[]"

  local local_skills
  local_skills="$(fetch_local_skill_index)"
  combined="$(echo "$combined" "$local_skills" | jq -s '.[0] + .[1]')"

  if check_skills_dependencies 2>/dev/null; then
    local default_skills
    default_skills="$(fetch_remote_skill_index "$DEFAULT_REMOTE" "$refresh")"
    combined="$(echo "$combined" "$default_skills" | jq -s '.[0] + .[1]')"

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

# Fetch all profiles from all registry tiers.
fetch_all_profile_indexes() {
  local refresh="${1:-false}"
  local combined="[]"

  local local_profiles
  local_profiles="$(fetch_local_profile_index)"
  combined="$(echo "$combined" "$local_profiles" | jq -s '.[0] + .[1]')"

  if check_skills_dependencies 2>/dev/null; then
    local default_profiles
    default_profiles="$(fetch_remote_profile_index "$DEFAULT_REMOTE" "$refresh")"
    combined="$(echo "$combined" "$default_profiles" | jq -s '.[0] + .[1]')"

    _ensure_registries_file
    local user_registries
    user_registries="$(jq -r '.[]' "$REGISTRIES_FILE")"
    if [[ -n "$user_registries" ]]; then
      while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local remote_profiles
        remote_profiles="$(fetch_remote_profile_index "$repo" "$refresh")"
        combined="$(echo "$combined" "$remote_profiles" | jq -s '.[0] + .[1]')"
      done <<< "$user_registries"
    fi
  fi

  echo "$combined"
}

# Fetch everything (skills + profiles) from all tiers.
fetch_all_indexes() {
  local refresh="${1:-false}"
  local skills profiles
  skills="$(fetch_all_skill_indexes "$refresh")"
  profiles="$(fetch_all_profile_indexes "$refresh")"
  echo "$skills" "$profiles" | jq -s '.[0] + .[1]'
}

# ── Find by name ──────────────────────────────────────────

# Search for a skill by name across all registries.
# Returns first match (tier order). Output: JSON object or empty.
find_skill() {
  local skill_name="$1"
  local refresh="${2:-false}"

  # Tier 1: Local
  local local_skills
  local_skills="$(fetch_local_skill_index)"
  local match
  match="$(echo "$local_skills" | jq --arg name "$skill_name" '[.[] | select(.name == $name)] | first // empty')"
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi

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

  # Tier 3: User-added
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

# Search for a profile by name across all registries.
find_profile() {
  local profile_name="$1"
  local refresh="${2:-false}"

  # Tier 1: Local
  local local_profiles
  local_profiles="$(fetch_local_profile_index)"
  local match
  match="$(echo "$local_profiles" | jq --arg name "$profile_name" '[.[] | select(.name == $name)] | first // empty')"
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi

  if ! check_skills_dependencies 2>/dev/null; then
    return 1
  fi

  # Tier 2: Default remote
  local default_profiles
  default_profiles="$(fetch_remote_profile_index "$DEFAULT_REMOTE" "$refresh")"
  match="$(echo "$default_profiles" | jq --arg name "$profile_name" '[.[] | select(.name == $name)] | first // empty')"
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi

  # Tier 3: User-added
  _ensure_registries_file
  local user_registries
  user_registries="$(jq -r '.[]' "$REGISTRIES_FILE")"
  if [[ -n "$user_registries" ]]; then
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      local remote_profiles
      remote_profiles="$(fetch_remote_profile_index "$repo" "$refresh")"
      match="$(echo "$remote_profiles" | jq --arg name "$profile_name" '[.[] | select(.name == $name)] | first // empty')"
      if [[ -n "$match" ]]; then
        echo "$match"
        return 0
      fi
    done <<< "$user_registries"
  fi

  return 1
}

# ── Download remote profile ──────────────────────────────

# Downloads all files in profiles/<name>/ from a remote registry
# to a temp directory. Returns the temp directory path.
download_remote_profile() {
  local profile_name="$1"
  local registry="$2"

  if ! check_skills_dependencies; then
    return 1
  fi

  local tree_json
  tree_json="$(_fetch_repo_tree "$registry")" || return 1

  local profile_prefix="profiles/$profile_name/"
  local file_paths
  file_paths="$(echo "$tree_json" | jq -r --arg prefix "$profile_prefix" \
    '.tree[] | select(.path | startswith($prefix)) | select(.type == "blob") | .path')"

  if [[ -z "$file_paths" ]]; then
    error "No files found for profile $profile_name in $registry"
    return 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue

    local rel_path="${file_path#$profile_prefix}"
    local target_file="$tmp_dir/$rel_path"
    mkdir -p "$(dirname "$target_file")"

    local content
    content="$(gh api "repos/$registry/contents/$file_path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || {
      warn "Failed to download: $file_path"
      continue
    }

    echo "$content" > "$target_file"
  done <<< "$file_paths"

  echo "$tmp_dir"
}
