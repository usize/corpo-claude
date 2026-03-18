#!/usr/bin/env bash
# lib/skills.sh — Install, uninstall, search, and list skills

INSTALLED_FILE="$CORPO_DATA_DIR/installed.json"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# ── Installed state tracking ──────────────────────────────

_ensure_installed_file() {
  ensure_data_dir
  if [[ ! -f "$INSTALLED_FILE" ]]; then
    echo '[]' > "$INSTALLED_FILE"
  fi
}

# Record an installed skill
_track_install() {
  local name="$1" registry="$2" scope="$3" path="$4"
  _ensure_installed_file

  # Remove existing entry for this name+scope if present (reinstall)
  local tmp
  tmp="$(mktemp)"
  jq --arg name "$name" --arg scope "$scope" \
    '[.[] | select(.name != $name or .scope != $scope)]' \
    "$INSTALLED_FILE" > "$tmp" && mv "$tmp" "$INSTALLED_FILE"

  # Add new entry
  tmp="$(mktemp)"
  jq --arg name "$name" --arg reg "$registry" --arg scope "$scope" --arg path "$path" \
    '. += [{"name": $name, "registry": $reg, "scope": $scope, "path": $path}]' \
    "$INSTALLED_FILE" > "$tmp" && mv "$tmp" "$INSTALLED_FILE"
}

# Remove tracking for an installed skill
_untrack_install() {
  local name="$1" scope="$2"
  _ensure_installed_file

  local tmp
  tmp="$(mktemp)"
  jq --arg name "$name" --arg scope "$scope" \
    '[.[] | select(.name != $name or .scope != $scope)]' \
    "$INSTALLED_FILE" > "$tmp" && mv "$tmp" "$INSTALLED_FILE"
}

# Check if a skill is installed (returns 0 if installed)
_is_installed() {
  local name="$1" scope="${2:-user}"
  _ensure_installed_file
  jq -e --arg name "$name" --arg scope "$scope" \
    '[.[] | select(.name == $name and .scope == $scope)] | length > 0' \
    "$INSTALLED_FILE" &>/dev/null
}

# ── Install ───────────────────────────────────────────────

cmd_install() {
  local skill_name=""
  local scope="user"
  local refresh="false"

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        scope="project"
        shift
        ;;
      --refresh)
        refresh="true"
        shift
        ;;
      -*)
        error "Unknown option: $1"
        return 1
        ;;
      *)
        skill_name="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$skill_name" ]]; then
    error "Usage: corpo-claude install <skill-name> [--project] [--refresh]"
    return 1
  fi

  # Determine target directory
  local target_dir
  if [[ "$scope" == "project" ]]; then
    target_dir=".claude/commands/$skill_name"
  else
    target_dir="$CLAUDE_HOME/commands/$skill_name"
  fi

  # Find the skill across registries
  info "Searching for skill: $skill_name..."
  local skill_info
  skill_info="$(find_skill "$skill_name" "$refresh")" || {
    error "Skill not found: $skill_name"
    echo ""
    echo "Try: corpo-claude search $skill_name"
    return 1
  }

  local registry
  registry="$(echo "$skill_info" | jq -r '.registry')"

  if [[ "$registry" == "local" ]]; then
    _install_local_skill "$skill_name" "$target_dir" "$scope"
  else
    _install_remote_skill "$skill_name" "$registry" "$target_dir" "$scope"
  fi
}

# Install a skill from the local skills/ directory
_install_local_skill() {
  local skill_name="$1" target_dir="$2" scope="$3"
  local source_dir="$CORPO_ROOT/skills/$skill_name"

  if [[ ! -d "$source_dir" ]]; then
    error "Local skill directory not found: $source_dir"
    return 1
  fi

  mkdir -p "$target_dir"
  cp -R "$source_dir"/* "$target_dir/"
  _track_install "$skill_name" "local" "$scope" "$target_dir"
  success "Installed $skill_name from local → $target_dir/"
}

# Install a skill from a remote GitHub registry
_install_remote_skill() {
  local skill_name="$1" registry="$2" target_dir="$3" scope="$4"

  if ! check_skills_dependencies; then
    return 1
  fi

  info "Fetching $skill_name from $registry..."

  # Get the file tree for the skill directory
  local tree_json
  tree_json="$(gh api "repos/$registry/git/trees/main?recursive=1" 2>/dev/null)" || {
    tree_json="$(gh api "repos/$registry/git/trees/master?recursive=1" 2>/dev/null)" || {
      error "Failed to fetch repository tree for $registry"
      return 1
    }
  }

  # Find all files under skills/<skill_name>/
  local skill_prefix="skills/$skill_name/"
  local file_paths
  file_paths="$(echo "$tree_json" | jq -r --arg prefix "$skill_prefix" \
    '.tree[] | select(.path | startswith($prefix)) | select(.type == "blob") | .path')"

  if [[ -z "$file_paths" ]]; then
    error "No files found for skill $skill_name in $registry"
    return 1
  fi

  mkdir -p "$target_dir"

  local failed=0
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue

    # Compute relative path within the skill directory
    local rel_path="${file_path#$skill_prefix}"
    local target_file="$target_dir/$rel_path"
    local target_file_dir
    target_file_dir="$(dirname "$target_file")"

    mkdir -p "$target_file_dir"

    # Download file content
    local content
    content="$(gh api "repos/$registry/contents/$file_path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || {
      warn "Failed to download: $file_path"
      failed=1
      continue
    }

    echo "$content" > "$target_file"
  done <<< "$file_paths"

  if [[ "$failed" -eq 1 ]]; then
    warn "Some files failed to download."
  fi

  _track_install "$skill_name" "$registry" "$scope" "$target_dir"
  success "Installed $skill_name from $registry → $target_dir/"
}

# ── Uninstall ─────────────────────────────────────────────

cmd_uninstall() {
  local skill_name=""
  local scope="user"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        scope="project"
        shift
        ;;
      -*)
        error "Unknown option: $1"
        return 1
        ;;
      *)
        skill_name="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$skill_name" ]]; then
    error "Usage: corpo-claude uninstall <skill-name> [--project]"
    return 1
  fi

  if ! _is_installed "$skill_name" "$scope"; then
    error "Skill not installed (scope=$scope): $skill_name"
    return 1
  fi

  # Get the install path
  _ensure_installed_file
  local install_path
  install_path="$(jq -r --arg name "$skill_name" --arg scope "$scope" \
    '[.[] | select(.name == $name and .scope == $scope)] | first | .path' \
    "$INSTALLED_FILE")"

  if [[ -n "$install_path" && -d "$install_path" ]]; then
    rm -rf "$install_path"
    success "Removed: $install_path"
  elif [[ -n "$install_path" && -f "$install_path" ]]; then
    rm -f "$install_path"
    success "Removed: $install_path"
  else
    warn "Install path not found: $install_path (already removed?)"
  fi

  _untrack_install "$skill_name" "$scope"
  success "Uninstalled: $skill_name (scope=$scope)"
}

# ── Search ────────────────────────────────────────────────

cmd_search() {
  local query="${1:-}"
  local refresh="false"

  # Check for --refresh flag
  for arg in "$@"; do
    if [[ "$arg" == "--refresh" ]]; then
      refresh="true"
    fi
  done

  info "Searching skill registries..."
  echo ""

  local all_skills
  all_skills="$(fetch_all_skill_indexes "$refresh")"

  local count
  count="$(echo "$all_skills" | jq 'length')"

  if [[ "$count" == "0" ]]; then
    warn "No skills found in any registry."
    return 0
  fi

  # Filter by query if provided
  local filtered
  if [[ -n "$query" && "$query" != "--refresh" ]]; then
    filtered="$(echo "$all_skills" | jq --arg q "$query" \
      '[.[] | select(.name | test($q; "i")) // select(.description | test($q; "i"))]')"
  else
    filtered="$all_skills"
  fi

  local filtered_count
  filtered_count="$(echo "$filtered" | jq 'length')"

  if [[ "$filtered_count" == "0" ]]; then
    warn "No skills matching '$query'."
    return 0
  fi

  gum style --bold --foreground 39 "Available Skills ($filtered_count)"
  echo ""

  echo "$filtered" | jq -r '.[] | "\(.name)\t\(.registry)\t\(.description)"' | while IFS=$'\t' read -r name registry desc; do
    local reg_label
    if [[ "$registry" == "local" ]]; then
      reg_label="local"
    else
      reg_label="$registry"
    fi

    if _has_gum; then
      gum style --foreground 76 "  $name" --bold
      gum style --foreground 250 "    registry: $reg_label"
      if [[ -n "$desc" ]]; then
        gum style --foreground 250 "    $desc"
      fi
    else
      echo "  $name  ($reg_label)"
      if [[ -n "$desc" ]]; then
        echo "    $desc"
      fi
    fi
    echo ""
  done
}

# ── List installed ────────────────────────────────────────

cmd_list() {
  _ensure_installed_file

  local count
  count="$(jq 'length' "$INSTALLED_FILE")"

  if [[ "$count" == "0" ]]; then
    info "No skills installed."
    echo ""
    echo "Install skills with: corpo-claude install <skill-name>"
    return 0
  fi

  gum style --bold --foreground 39 "Installed Skills ($count)"
  echo ""

  jq -r '.[] | "\(.name)\t\(.scope)\t\(.registry)\t\(.path)"' "$INSTALLED_FILE" | while IFS=$'\t' read -r name scope registry path; do
    if _has_gum; then
      gum style --foreground 76 "  $name" --bold
      gum style --foreground 250 "    scope: $scope  |  registry: $registry"
      gum style --foreground 250 "    path: $path"
    else
      echo "  $name  (scope=$scope, registry=$registry)"
      echo "    $path"
    fi
    echo ""
  done
}
