#!/usr/bin/env bash
# lib/init.sh — Apply a profile to user or project scope

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

cmd_init() {
  # Parse --project / --global alongside --profile flags
  local scope="unset"
  local raw_args=("$@")
  local filtered_args=()

  for arg in "${raw_args[@]}"; do
    case "$arg" in
      --project) scope="project" ;;
      --global)  scope="user" ;;
      *)         filtered_args+=("$arg") ;;
    esac
  done

  parse_profile_flags "${filtered_args[@]}"
  select_profiles_interactive || return 1

  # Prompt for scope if neither flag was given
  if [[ "$scope" == "unset" ]]; then
    scope="$(gum choose --header "Apply profile to which scope?" \
      "global   — ~/.claude/ (all projects)" \
      "project  — ./.claude/ (this project only)")"
    case "$scope" in
      project*) scope="project" ;;
      *)        scope="user" ;;
    esac
  fi

  header "corpo-claude init"
  echo ""

  # Merge profiles
  local merged_file
  merged_file="$(merge_profiles "${SELECTED_PROFILES[@]}")" || return 1
  trap "rm -f '$merged_file'" RETURN

  info "Profiles: ${SELECTED_PROFILES[*]}"
  info "Scope: $scope"
  echo ""

  if [[ "$scope" == "project" ]]; then
    _init_project_scope "$merged_file"
  else
    _init_user_scope "$merged_file"
  fi
}

# ── User scope (global) ──────────────────────────────────────

_init_user_scope() {
  local merged_file="$1"
  local actions=()

  # ── Provider ───────────────────────────────────────────────
  local provider_type="" provider_region="" project_id=""
  if profile_has "$merged_file" ".provider"; then
    provider_type="$(profile_get "$merged_file" '.provider.type')"
    provider_region="$(profile_get "$merged_file" '.provider.region // "us-east5"')"

    case "$provider_type" in
      vertex)
        actions+=("Set CLAUDE_CODE_USE_VERTEX=1, CLOUD_ML_REGION=$provider_region in settings")
        project_id="$(gum input --placeholder "Enter your GCP project ID" --header "Vertex AI Project ID")"
        if [[ -z "$project_id" ]]; then
          error "Project ID is required for Vertex provider."
          return 1
        fi
        actions+=("Set ANTHROPIC_VERTEX_PROJECT_ID=$project_id in settings")
        ;;
      bedrock)
        actions+=("Set CLAUDE_CODE_USE_BEDROCK=1, AWS_REGION=$provider_region in settings")
        ;;
      *)
        warn "Unknown provider type: $provider_type"
        ;;
    esac
  fi

  # ── CLAUDE.md ──────────────────────────────────────────────
  local claude_md_src=""
  if profile_has "$merged_file" ".claude_md"; then
    claude_md_src="$(profile_get "$merged_file" '.claude_md')"
    actions+=("Copy CLAUDE.md → $CLAUDE_HOME/CLAUDE.md")
  fi

  # ── MCP Servers ────────────────────────────────────────────
  local mcp_count
  mcp_count="$(profile_get "$merged_file" '.mcp_servers | length')"
  if [[ "$mcp_count" != "0" && "$mcp_count" != "null" ]]; then
    local i=0
    while [[ $i -lt $mcp_count ]]; do
      local name stype package
      name="$(profile_get "$merged_file" ".mcp_servers[$i].name")"
      stype="$(profile_get "$merged_file" ".mcp_servers[$i].type")"
      package="$(profile_get "$merged_file" ".mcp_servers[$i].package")"
      actions+=("Install MCP server: $name ($stype: $package)")
      i=$((i + 1))
    done
  fi

  # ── Hooks ──────────────────────────────────────────────────
  if profile_has "$merged_file" ".hooks"; then
    actions+=("Write hooks to $CLAUDE_HOME/settings.json")
  fi

  # ── Skills ─────────────────────────────────────────────────
  local skill_count
  skill_count="$(profile_get "$merged_file" '.skills | length')"
  if [[ "$skill_count" != "0" && "$skill_count" != "null" ]]; then
    local k=0
    while [[ $k -lt $skill_count ]]; do
      local skill
      skill="$(profile_get "$merged_file" ".skills[$k]")"
      actions+=("Copy skill: $(basename "$skill") → $CLAUDE_HOME/commands/")
      k=$((k + 1))
    done
  fi

  # ── Confirmation ───────────────────────────────────────────
  if [[ ${#actions[@]} -eq 0 ]]; then
    warn "Nothing to do — profile has no user-scope configuration."
    return 0
  fi

  gum style --bold --foreground 39 "The following changes will be applied (user scope):"
  for action in "${actions[@]}"; do
    gum style "  • $action"
  done
  echo ""

  if ! gum confirm "Apply these changes?"; then
    warn "Aborted."
    return 0
  fi

  echo ""

  # ── Apply ──────────────────────────────────────────────────
  if [[ -n "$provider_type" ]]; then
    _init_provider "$provider_type" "$provider_region" "$project_id"
  fi

  if [[ -n "$claude_md_src" ]]; then
    _init_claude_md "$claude_md_src" "$CLAUDE_HOME"
  fi

  if [[ "$mcp_count" != "0" && "$mcp_count" != "null" ]]; then
    _init_mcp_servers "$merged_file" "$mcp_count"
  fi

  if profile_has "$merged_file" ".hooks"; then
    _init_hooks "$merged_file"
  fi

  if [[ "$skill_count" != "0" && "$skill_count" != "null" ]]; then
    _init_skills "$merged_file" "$skill_count" "$CLAUDE_HOME/commands"
  fi

  if [[ -n "$provider_type" ]]; then
    echo ""
    validate_auth "$provider_type"
  fi

  echo ""
  success "Init complete! (user scope)"
}

# ── Project scope ─────────────────────────────────────────────

_init_project_scope() {
  local merged_file="$1"
  local project_claude_dir=".claude"

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    warn "Not inside a git repository. Proceeding in current directory."
  fi

  if ! profile_has "$merged_file" ".project_template"; then
    warn "No project_template defined in the selected profile(s). Nothing to apply."
    return 0
  fi

  local actions=()

  # ── CLAUDE.md ──────────────────────────────────────────────
  local pt_claude_md=""
  if profile_has "$merged_file" ".project_template.claude_md"; then
    pt_claude_md="$(profile_get "$merged_file" '.project_template.claude_md')"
    actions+=("Copy CLAUDE.md → $project_claude_dir/CLAUDE.md")
  fi

  # ── Settings ───────────────────────────────────────────────
  local has_settings=false
  if profile_has "$merged_file" ".project_template.settings"; then
    has_settings=true
    actions+=("Write settings to $project_claude_dir/settings.json")
  fi

  # ── Commands ───────────────────────────────────────────────
  local cmd_count
  cmd_count="$(profile_get "$merged_file" '.project_template.commands | length')"
  if [[ "$cmd_count" != "0" && "$cmd_count" != "null" ]]; then
    local m=0
    while [[ $m -lt $cmd_count ]]; do
      local tcmd
      tcmd="$(profile_get "$merged_file" ".project_template.commands[$m]")"
      actions+=("Copy command: $(basename "$tcmd") → $project_claude_dir/commands/")
      m=$((m + 1))
    done
  fi

  # ── Rules ──────────────────────────────────────────────────
  local rule_count
  rule_count="$(profile_get "$merged_file" '.project_template.rules | length')"
  if [[ "$rule_count" != "0" && "$rule_count" != "null" ]]; then
    local n=0
    while [[ $n -lt $rule_count ]]; do
      local rule
      rule="$(profile_get "$merged_file" ".project_template.rules[$n]")"
      actions+=("Copy rule: $(basename "$rule") → $project_claude_dir/rules/")
      n=$((n + 1))
    done
  fi

  # ── Confirmation ───────────────────────────────────────────
  if [[ ${#actions[@]} -eq 0 ]]; then
    warn "project_template section is empty. Nothing to apply."
    return 0
  fi

  gum style --bold --foreground 39 "The following files will be created in $(pwd)/$project_claude_dir/ (project scope):"
  for action in "${actions[@]}"; do
    gum style "  • $action"
  done
  echo ""

  if ! gum confirm "Apply these changes?"; then
    warn "Aborted."
    return 0
  fi

  echo ""

  # ── Apply ──────────────────────────────────────────────────
  mkdir -p "$project_claude_dir"

  if [[ -n "$pt_claude_md" ]]; then
    if [[ ! -f "$pt_claude_md" ]]; then
      error "Project CLAUDE.md source not found: $pt_claude_md"
    else
      cp "$pt_claude_md" "$project_claude_dir/CLAUDE.md"
      success "CLAUDE.md → $project_claude_dir/CLAUDE.md"
    fi
  fi

  if [[ "$has_settings" == true ]]; then
    local settings_json
    settings_json="$(yq eval -o json '.project_template.settings' "$merged_file")"

    local settings_file="$project_claude_dir/settings.json"
    if [[ -f "$settings_file" ]]; then
      local tmp
      tmp="$(mktemp)"
      jq --argjson new "$settings_json" '. * $new' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
    else
      echo "$settings_json" | jq '.' > "$settings_file"
    fi
    success "Settings → $settings_file"
  fi

  if [[ "$cmd_count" != "0" && "$cmd_count" != "null" ]]; then
    mkdir -p "$project_claude_dir/commands"
    local m=0
    while [[ $m -lt $cmd_count ]]; do
      local tcmd filename
      tcmd="$(profile_get "$merged_file" ".project_template.commands[$m]")"
      if [[ ! -f "$tcmd" ]]; then
        warn "Command file not found: $tcmd"
      else
        filename="$(basename "$tcmd")"
        cp "$tcmd" "$project_claude_dir/commands/$filename"
        success "Command: $filename → $project_claude_dir/commands/"
      fi
      m=$((m + 1))
    done
  fi

  if [[ "$rule_count" != "0" && "$rule_count" != "null" ]]; then
    mkdir -p "$project_claude_dir/rules"
    local n=0
    while [[ $n -lt $rule_count ]]; do
      local rule filename
      rule="$(profile_get "$merged_file" ".project_template.rules[$n]")"
      if [[ ! -f "$rule" ]]; then
        warn "Rule file not found: $rule"
      else
        filename="$(basename "$rule")"
        cp "$rule" "$project_claude_dir/rules/$filename"
        success "Rule: $filename → $project_claude_dir/rules/"
      fi
      n=$((n + 1))
    done
  fi

  echo ""
  success "Init complete! (project scope)"
}

# ── Shared helpers ────────────────────────────────────────────

_init_provider() {
  local ptype="$1" pregion="$2" project_id="$3"
  local settings_file="$CLAUDE_HOME/settings.json"

  mkdir -p "$CLAUDE_HOME"

  if [[ ! -f "$settings_file" ]]; then
    echo '{}' > "$settings_file"
  fi

  local tmp
  tmp="$(mktemp)"

  case "$ptype" in
    vertex)
      jq --arg region "$pregion" --arg project "$project_id" '
        .env = (.env // {}) |
        .env.CLAUDE_CODE_USE_VERTEX = "1" |
        .env.CLOUD_ML_REGION = $region |
        .env.ANTHROPIC_VERTEX_PROJECT_ID = $project
      ' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
      success "Provider: Vertex AI configured (region=$pregion, project=$project_id)"
      ;;
    bedrock)
      jq --arg region "$pregion" '
        .env = (.env // {}) |
        .env.CLAUDE_CODE_USE_BEDROCK = "1" |
        .env.AWS_REGION = $region
      ' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
      success "Provider: Bedrock configured (region=$pregion)"
      ;;
  esac
}

_init_claude_md() {
  local src="$1"
  local target_dir="$2"

  if [[ ! -f "$src" ]]; then
    error "CLAUDE.md source not found: $src"
    return 1
  fi

  mkdir -p "$target_dir"
  cp "$src" "$target_dir/CLAUDE.md"
  success "CLAUDE.md copied to $target_dir/CLAUDE.md"
}

_init_mcp_servers() {
  local merged_file="$1" count="$2"
  local i=0

  while [[ $i -lt $count ]]; do
    local name stype package
    name="$(profile_get "$merged_file" ".mcp_servers[$i].name")"
    stype="$(profile_get "$merged_file" ".mcp_servers[$i].type")"
    package="$(profile_get "$merged_file" ".mcp_servers[$i].package")"

    info "Installing MCP server: $name..."
    if claude mcp add "$name" -- "$stype" -y "$package" 2>/dev/null; then
      success "MCP server installed: $name"
    else
      warn "Failed to install MCP server: $name (claude CLI may not be available)"
    fi
    i=$((i + 1))
  done
}

_init_hooks() {
  local merged_file="$1"
  local settings_file="$CLAUDE_HOME/settings.json"

  mkdir -p "$CLAUDE_HOME"

  if [[ ! -f "$settings_file" ]]; then
    echo '{}' > "$settings_file"
  fi

  local hooks_json
  hooks_json="$(yq eval -o json '.hooks' "$merged_file")"

  local claude_hooks
  claude_hooks="$(echo "$hooks_json" | jq '
    to_entries | map(
      .key as $event |
      .value | map({
        matcher: .matcher,
        hooks: [{ type: "command", command: .command }]
      }) | { ($event): . }
    ) | add // {}
  ')"

  local tmp
  tmp="$(mktemp)"
  jq --argjson hooks "$claude_hooks" '.hooks = $hooks' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
  success "Hooks written to $settings_file"
}

_init_skills() {
  local merged_file="$1" count="$2" commands_dir="$3"

  mkdir -p "$commands_dir"

  local k=0
  while [[ $k -lt $count ]]; do
    local skill
    skill="$(profile_get "$merged_file" ".skills[$k]")"

    if [[ ! -f "$skill" ]]; then
      warn "Skill file not found: $skill"
    else
      local filename
      filename="$(basename "$skill")"
      cp "$skill" "$commands_dir/$filename"
      success "Skill copied: $filename → $commands_dir/"
    fi
    k=$((k + 1))
  done
}
