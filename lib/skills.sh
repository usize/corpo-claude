#!/usr/bin/env bash
# lib/skills.sh — Skill and profile subcommand routers + install/uninstall/search/list

INSTALLED_FILE="$CORPO_DATA_DIR/installed.json"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

# ── Subcommand routers ───────────────────────────────────

cmd_skill() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: corpo-claude skill <search|install|uninstall|list> [args]"
    return 1
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    search)    cmd_skill_search "$@" ;;
    install)   cmd_skill_install "$@" ;;
    uninstall) cmd_skill_uninstall "$@" ;;
    list)      cmd_skill_list "$@" ;;
    *)
      error "Unknown skill subcommand: $subcmd"
      echo "Usage: corpo-claude skill <search|install|uninstall|list> [args]"
      return 1
      ;;
  esac
}

cmd_profile() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: corpo-claude profile <search|list> [args]"
    return 1
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    search) cmd_profile_search "$@" ;;
    list)   cmd_profile_list "$@" ;;
    *)
      error "Unknown profile subcommand: $subcmd"
      echo "Usage: corpo-claude profile <search|list> [args]"
      return 1
      ;;
  esac
}

# ── Installed state tracking ──────────────────────────────

_ensure_installed_file() {
  ensure_data_dir
  if [[ ! -f "$INSTALLED_FILE" ]]; then
    echo '[]' > "$INSTALLED_FILE"
  fi
}

_track_install() {
  local name="$1" registry="$2" scope="$3" path="$4"
  _ensure_installed_file

  local tmp
  tmp="$(mktemp)"
  jq --arg name "$name" --arg scope "$scope" \
    '[.[] | select(.name != $name or .scope != $scope)]' \
    "$INSTALLED_FILE" > "$tmp" && mv "$tmp" "$INSTALLED_FILE"

  tmp="$(mktemp)"
  jq --arg name "$name" --arg reg "$registry" --arg scope "$scope" --arg path "$path" \
    '. += [{"name": $name, "registry": $reg, "scope": $scope, "path": $path}]' \
    "$INSTALLED_FILE" > "$tmp" && mv "$tmp" "$INSTALLED_FILE"
}

_untrack_install() {
  local name="$1" scope="$2"
  _ensure_installed_file

  local tmp
  tmp="$(mktemp)"
  jq --arg name "$name" --arg scope "$scope" \
    '[.[] | select(.name != $name or .scope != $scope)]' \
    "$INSTALLED_FILE" > "$tmp" && mv "$tmp" "$INSTALLED_FILE"
}

_is_installed() {
  local name="$1" scope="${2:-user}"
  _ensure_installed_file
  jq -e --arg name "$name" --arg scope "$scope" \
    '[.[] | select(.name == $name and .scope == $scope)] | length > 0' \
    "$INSTALLED_FILE" &>/dev/null
}

# ── skill install ─────────────────────────────────────────

cmd_skill_install() {
  local skill_name=""
  local scope="user"
  local refresh="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) scope="project"; shift ;;
      --refresh) refresh="true"; shift ;;
      -*) error "Unknown option: $1"; return 1 ;;
      *)  skill_name="$1"; shift ;;
    esac
  done

  if [[ -z "$skill_name" ]]; then
    error "Usage: corpo-claude skill install <name> [--project] [--refresh]"
    return 1
  fi

  local target_dir
  if [[ "$scope" == "project" ]]; then
    target_dir=".claude/commands/$skill_name"
  else
    target_dir="$CLAUDE_HOME/commands/$skill_name"
  fi

  info "Searching for skill: $skill_name..."
  local skill_info
  skill_info="$(find_skill "$skill_name" "$refresh")" || {
    error "Skill not found: $skill_name"
    echo ""
    echo "Try: corpo-claude skill search $skill_name"
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

_install_remote_skill() {
  local skill_name="$1" registry="$2" target_dir="$3" scope="$4"

  if ! check_skills_dependencies; then
    return 1
  fi

  info "Fetching $skill_name from $registry..."

  local tree_json
  tree_json="$(_fetch_repo_tree "$registry")" || {
    error "Failed to fetch repository tree for $registry"
    return 1
  }

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

    local rel_path="${file_path#$skill_prefix}"
    local target_file="$target_dir/$rel_path"
    mkdir -p "$(dirname "$target_file")"

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

# ── skill uninstall ───────────────────────────────────────

cmd_skill_uninstall() {
  local skill_name=""
  local scope="user"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) scope="project"; shift ;;
      -*) error "Unknown option: $1"; return 1 ;;
      *)  skill_name="$1"; shift ;;
    esac
  done

  if [[ -z "$skill_name" ]]; then
    error "Usage: corpo-claude skill uninstall <name> [--project]"
    return 1
  fi

  if ! _is_installed "$skill_name" "$scope"; then
    error "Skill not installed (scope=$scope): $skill_name"
    return 1
  fi

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

# ── skill search ──────────────────────────────────────────

cmd_skill_search() {
  local query="${1:-}"
  local refresh="false"

  for arg in "$@"; do
    [[ "$arg" == "--refresh" ]] && refresh="true"
  done

  info "Searching for skills..."
  echo ""

  local all_skills
  all_skills="$(fetch_all_skill_indexes "$refresh")"

  local filtered
  if [[ -n "$query" && "$query" != "--refresh" ]]; then
    filtered="$(echo "$all_skills" | jq --arg q "$query" \
      '[.[] | select((.name | test($q; "i")) or (.description | test($q; "i")))]')"
  else
    filtered="$all_skills"
  fi

  local count
  count="$(echo "$filtered" | jq 'length')"

  if [[ "$count" == "0" ]]; then
    if [[ -n "$query" && "$query" != "--refresh" ]]; then
      warn "No skills matching '$query'."
    else
      warn "No skills found in any registry."
    fi
    return 0
  fi

  gum style --bold --foreground 39 "Skills ($count)"
  echo ""
  _display_items "$filtered"
}

# ── skill list ────────────────────────────────────────────

cmd_skill_list() {
  _ensure_installed_file

  local count
  count="$(jq 'length' "$INSTALLED_FILE")"

  if [[ "$count" == "0" ]]; then
    info "No skills installed."
    echo ""
    echo "Install skills with: corpo-claude skill install <name>"
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

# ── profile search ────────────────────────────────────────

cmd_profile_search() {
  local query="${1:-}"
  local refresh="false"

  for arg in "$@"; do
    [[ "$arg" == "--refresh" ]] && refresh="true"
  done

  info "Searching for profiles..."
  echo ""

  local all_profiles
  all_profiles="$(fetch_all_profile_indexes "$refresh")"

  local filtered
  if [[ -n "$query" && "$query" != "--refresh" ]]; then
    filtered="$(echo "$all_profiles" | jq --arg q "$query" \
      '[.[] | select((.name | test($q; "i")) or (.description | test($q; "i")))]')"
  else
    filtered="$all_profiles"
  fi

  local count
  count="$(echo "$filtered" | jq 'length')"

  if [[ "$count" == "0" ]]; then
    if [[ -n "$query" && "$query" != "--refresh" ]]; then
      warn "No profiles matching '$query'."
    else
      warn "No profiles found in any registry."
    fi
    return 0
  fi

  gum style --bold --foreground 39 "Profiles ($count)"
  echo ""
  _display_items "$filtered"
}

# ── profile list ──────────────────────────────────────────

cmd_profile_list() {
  local available
  available="$(list_profiles 2>/dev/null)" || {
    info "No profiles found locally."
    return 0
  }

  local count
  count="$(echo "$available" | wc -l | tr -d ' ')"

  gum style --bold --foreground 39 "Local Profiles ($count)"
  echo ""

  while IFS= read -r name; do
    if _has_gum; then
      gum style --foreground 76 "  $name" --bold
    else
      echo "  $name"
    fi
  done <<< "$available"
  echo ""

  echo "Use 'corpo-claude profile search' to find profiles from all registries."
}

# ── Display helper ────────────────────────────────────────

_display_items() {
  local items_json="$1"

  echo "$items_json" | jq -r '.[] | "\(.name)\t\(.registry)\t\(.description // "")"' | while IFS=$'\t' read -r name registry desc; do
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
