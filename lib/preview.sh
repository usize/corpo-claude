#!/usr/bin/env bash
# lib/preview.sh — Dry-run display of what would be written

cmd_preview() {
  parse_profile_flags "$@"
  select_profiles_interactive || return 1

  header "corpo-claude preview"
  echo ""

  # Merge profiles
  local merged_file
  merged_file="$(merge_profiles "${SELECTED_PROFILES[@]}")" || return 1
  trap "rm -f '$merged_file'" RETURN

  info "Profiles: ${SELECTED_PROFILES[*]}"
  echo ""

  # ── Provider ───────────────────────────────────────────────
  if profile_has "$merged_file" ".provider"; then
    local ptype pregion
    ptype="$(profile_get "$merged_file" '.provider.type')"
    pregion="$(profile_get "$merged_file" '.provider.region // "not set"')"

    gum style --bold --foreground 39 "Provider"
    gum style "  Type:   $ptype"
    gum style "  Region: $pregion"

    case "$ptype" in
      vertex)
        gum style "  → Will set CLAUDE_CODE_USE_VERTEX=1 in env"
        gum style "  → Will set CLOUD_ML_REGION=$pregion in env"
        gum style "  → Will prompt for ANTHROPIC_VERTEX_PROJECT_ID"
        ;;
      bedrock)
        gum style "  → Will set CLAUDE_CODE_USE_BEDROCK=1 in env"
        gum style "  → Will set AWS_REGION=$pregion in env"
        ;;
    esac
    echo ""
  fi

  # ── CLAUDE.md (user scope) ────────────────────────────────
  if profile_has "$merged_file" ".claude_md"; then
    local claude_md_src
    claude_md_src="$(profile_get "$merged_file" '.claude_md')"

    gum style --bold --foreground 39 "User CLAUDE.md"
    gum style "  Source: $claude_md_src"
    gum style "  → Will copy to ~/.claude/CLAUDE.md"
    echo ""
  fi

  # ── MCP Servers ────────────────────────────────────────────
  local mcp_count
  mcp_count="$(profile_get "$merged_file" '.mcp_servers | length')"
  if [[ "$mcp_count" != "0" && "$mcp_count" != "null" ]]; then
    gum style --bold --foreground 39 "MCP Servers ($mcp_count)"
    local i=0
    while [[ $i -lt $mcp_count ]]; do
      local name stype package
      name="$(profile_get "$merged_file" ".mcp_servers[$i].name")"
      stype="$(profile_get "$merged_file" ".mcp_servers[$i].type")"
      package="$(profile_get "$merged_file" ".mcp_servers[$i].package")"
      gum style "  • $name ($stype: $package)"
      gum style "    → claude mcp add $name -- $stype -y $package"
      i=$((i + 1))
    done
    echo ""
  fi

  # ── Hooks ──────────────────────────────────────────────────
  if profile_has "$merged_file" ".hooks"; then
    gum style --bold --foreground 39 "Hooks"
    local hook_events
    hook_events="$(profile_get "$merged_file" '.hooks | keys | .[]')"
    while IFS= read -r event; do
      [[ -z "$event" ]] && continue
      local hook_count
      hook_count="$(profile_get "$merged_file" ".hooks.$event | length")"
      local j=0
      while [[ $j -lt $hook_count ]]; do
        local matcher hcmd
        matcher="$(profile_get "$merged_file" ".hooks.$event[$j].matcher")"
        hcmd="$(profile_get "$merged_file" ".hooks.$event[$j].command")"
        gum style "  • $event [matcher: $matcher]"
        gum style "    command: $hcmd"
        j=$((j + 1))
      done
    done <<< "$hook_events"
    gum style "  → Will write to ~/.claude/settings.json"
    echo ""
  fi

  # ── Skills ─────────────────────────────────────────────────
  local skill_count
  skill_count="$(profile_get "$merged_file" '.skills | length')"
  if [[ "$skill_count" != "0" && "$skill_count" != "null" ]]; then
    gum style --bold --foreground 39 "Skills ($skill_count)"
    local k=0
    while [[ $k -lt $skill_count ]]; do
      local skill
      skill="$(profile_get "$merged_file" ".skills[$k]")"
      gum style "  • $skill"
      gum style "    → Will copy to ~/.claude/commands/"
      k=$((k + 1))
    done
    echo ""
  fi

  # ── Project Template ───────────────────────────────────────
  if profile_has "$merged_file" ".project_template"; then
    gum style --bold --foreground 39 "Project Template (scaffold)"

    if profile_has "$merged_file" ".project_template.claude_md"; then
      local pt_claude_md
      pt_claude_md="$(profile_get "$merged_file" '.project_template.claude_md')"
      gum style "  CLAUDE.md: $pt_claude_md"
      gum style "    → Will copy to ./.claude/CLAUDE.md"
    fi

    if profile_has "$merged_file" ".project_template.settings"; then
      gum style "  Settings:"
      local settings_json
      settings_json="$(profile_get "$merged_file" '.project_template.settings' -o json)"
      echo "$settings_json" | while IFS= read -r line; do
        gum style "    $line"
      done
    fi

    local cmd_count
    cmd_count="$(profile_get "$merged_file" '.project_template.commands | length')"
    if [[ "$cmd_count" != "0" && "$cmd_count" != "null" ]]; then
      gum style "  Commands ($cmd_count):"
      local m=0
      while [[ $m -lt $cmd_count ]]; do
        local tcmd
        tcmd="$(profile_get "$merged_file" ".project_template.commands[$m]")"
        gum style "    • $tcmd → ./.claude/commands/"
        m=$((m + 1))
      done
    fi

    local rule_count
    rule_count="$(profile_get "$merged_file" '.project_template.rules | length')"
    if [[ "$rule_count" != "0" && "$rule_count" != "null" ]]; then
      gum style "  Rules ($rule_count):"
      local n=0
      while [[ $n -lt $rule_count ]]; do
        local rule
        rule="$(profile_get "$merged_file" ".project_template.rules[$n]")"
        gum style "    • $rule → ./.claude/rules/"
        n=$((n + 1))
      done
    fi
    echo ""
  fi

  success "Preview complete. No changes were made."
}
