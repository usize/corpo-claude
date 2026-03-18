#!/usr/bin/env bash
# lib/init.sh — User-scope setup (provider, MCP, claude_md, hooks, skills)

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

cmd_init() {
  parse_profile_flags "$@"
  select_profiles_interactive || return 1

  header "corpo-claude init"
  echo ""

  # Merge profiles
  local merged_file
  merged_file="$(merge_profiles "${SELECTED_PROFILES[@]}")" || return 1
  trap "rm -f '$merged_file'" RETURN

  info "Profiles: ${SELECTED_PROFILES[*]}"
  echo ""

  # Collect actions to describe before confirming
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
    actions+=("Copy $claude_md_src → $CLAUDE_HOME/CLAUDE.md")
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
      actions+=("Copy skill: $skill → $CLAUDE_HOME/commands/")
      k=$((k + 1))
    done
  fi

  # ── Confirmation ───────────────────────────────────────────
  if [[ ${#actions[@]} -eq 0 ]]; then
    warn "Nothing to do — profile has no init-relevant configuration."
    return 0
  fi

  gum style --bold --foreground 39 "The following changes will be applied:"
  for action in "${actions[@]}"; do
    gum style "  • $action"
  done
  echo ""

  if ! gum confirm "Apply these changes?"; then
    warn "Aborted."
    return 0
  fi

  echo ""

  # ── Apply: Provider ────────────────────────────────────────
  if [[ -n "$provider_type" ]]; then
    _init_provider "$provider_type" "$provider_region" "$project_id"
  fi

  # ── Apply: CLAUDE.md ───────────────────────────────────────
  if [[ -n "$claude_md_src" ]]; then
    _init_claude_md "$claude_md_src"
  fi

  # ── Apply: MCP Servers ─────────────────────────────────────
  if [[ "$mcp_count" != "0" && "$mcp_count" != "null" ]]; then
    _init_mcp_servers "$merged_file" "$mcp_count"
  fi

  # ── Apply: Hooks ───────────────────────────────────────────
  if profile_has "$merged_file" ".hooks"; then
    _init_hooks "$merged_file"
  fi

  # ── Apply: Skills ──────────────────────────────────────────
  if [[ "$skill_count" != "0" && "$skill_count" != "null" ]]; then
    _init_skills "$merged_file" "$skill_count"
  fi

  # ── Auth validation ──────────────────────────────────────
  if [[ -n "$provider_type" ]]; then
    echo ""
    validate_auth "$provider_type"
  fi

  echo ""
  success "Init complete!"
}

# ── Provider setup ─────────────────────────────────────────────

_init_provider() {
  local ptype="$1" pregion="$2" project_id="$3"
  local settings_file="$CLAUDE_HOME/settings.json"

  mkdir -p "$CLAUDE_HOME"

  # Ensure settings file exists
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

# ── CLAUDE.md copy ─────────────────────────────────────────────

_init_claude_md() {
  local src="$1"

  if [[ ! -f "$src" ]]; then
    error "CLAUDE.md source not found: $src"
    return 1
  fi

  mkdir -p "$CLAUDE_HOME"
  cp "$src" "$CLAUDE_HOME/CLAUDE.md"
  success "CLAUDE.md copied to $CLAUDE_HOME/CLAUDE.md"
}

# ── MCP server installation ───────────────────────────────────

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

# ── Hooks ──────────────────────────────────────────────────────

_init_hooks() {
  local merged_file="$1"
  local settings_file="$CLAUDE_HOME/settings.json"

  mkdir -p "$CLAUDE_HOME"

  if [[ ! -f "$settings_file" ]]; then
    echo '{}' > "$settings_file"
  fi

  # Build hooks JSON from the profile
  local hooks_json
  hooks_json="$(yq eval -o json '.hooks' "$merged_file")"

  # Transform the profile hooks format into Claude Code settings format:
  # { "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "..." }] }] } }
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

# ── Skills ─────────────────────────────────────────────────────

_init_skills() {
  local merged_file="$1" count="$2"
  local commands_dir="$CLAUDE_HOME/commands"

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
