#!/usr/bin/env bash
# lib/scaffold.sh — Project-scope .claude/ generation from project_template

cmd_scaffold() {
  parse_profile_flags "$@"
  select_profiles_interactive || return 1

  header "corpo-claude scaffold"
  echo ""

  # Check for git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    warn "Not inside a git repository. Scaffolding will proceed in the current directory."
  fi

  # Merge profiles
  local merged_file
  merged_file="$(merge_profiles "${SELECTED_PROFILES[@]}")" || return 1
  trap "rm -f '$merged_file'" RETURN

  info "Profiles: ${SELECTED_PROFILES[*]}"
  echo ""

  if ! profile_has "$merged_file" ".project_template"; then
    warn "No project_template defined in the selected profile(s). Nothing to scaffold."
    return 0
  fi

  local project_claude_dir=".claude"
  local actions=()

  # ── CLAUDE.md ──────────────────────────────────────────────
  local pt_claude_md=""
  if profile_has "$merged_file" ".project_template.claude_md"; then
    pt_claude_md="$(profile_get "$merged_file" '.project_template.claude_md')"
    actions+=("Copy $pt_claude_md → $project_claude_dir/CLAUDE.md")
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
      actions+=("Copy command: $tcmd → $project_claude_dir/commands/")
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
      actions+=("Copy rule: $rule → $project_claude_dir/rules/")
      n=$((n + 1))
    done
  fi

  # ── Confirmation ───────────────────────────────────────────
  if [[ ${#actions[@]} -eq 0 ]]; then
    warn "project_template section is empty. Nothing to scaffold."
    return 0
  fi

  gum style --bold --foreground 39 "The following files will be created in $(pwd)/$project_claude_dir/:"
  for action in "${actions[@]}"; do
    gum style "  • $action"
  done
  echo ""

  if ! gum confirm "Scaffold project?"; then
    warn "Aborted."
    return 0
  fi

  echo ""

  # ── Apply ──────────────────────────────────────────────────
  mkdir -p "$project_claude_dir"

  # CLAUDE.md
  if [[ -n "$pt_claude_md" ]]; then
    local resolved
    resolved="$(resolve_path "$pt_claude_md")"
    if [[ ! -f "$resolved" ]]; then
      error "Project CLAUDE.md source not found: $resolved"
    else
      cp "$resolved" "$project_claude_dir/CLAUDE.md"
      success "CLAUDE.md → $project_claude_dir/CLAUDE.md"
    fi
  fi

  # Settings
  if [[ "$has_settings" == true ]]; then
    local settings_json
    settings_json="$(yq eval -o json '.project_template.settings' "$merged_file")"

    local settings_file="$project_claude_dir/settings.json"
    if [[ -f "$settings_file" ]]; then
      # Merge with existing
      local tmp
      tmp="$(mktemp)"
      jq --argjson new "$settings_json" '. * $new' "$settings_file" > "$tmp" && mv "$tmp" "$settings_file"
    else
      echo "$settings_json" | jq '.' > "$settings_file"
    fi
    success "Settings → $settings_file"
  fi

  # Commands
  if [[ "$cmd_count" != "0" && "$cmd_count" != "null" ]]; then
    mkdir -p "$project_claude_dir/commands"
    local m=0
    while [[ $m -lt $cmd_count ]]; do
      local tcmd resolved filename
      tcmd="$(profile_get "$merged_file" ".project_template.commands[$m]")"
      resolved="$(resolve_path "$tcmd")"
      if [[ ! -f "$resolved" ]]; then
        warn "Command file not found: $resolved"
      else
        filename="$(basename "$resolved")"
        cp "$resolved" "$project_claude_dir/commands/$filename"
        success "Command: $filename → $project_claude_dir/commands/"
      fi
      m=$((m + 1))
    done
  fi

  # Rules
  if [[ "$rule_count" != "0" && "$rule_count" != "null" ]]; then
    mkdir -p "$project_claude_dir/rules"
    local n=0
    while [[ $n -lt $rule_count ]]; do
      local rule resolved filename
      rule="$(profile_get "$merged_file" ".project_template.rules[$n]")"
      resolved="$(resolve_path "$rule")"
      if [[ ! -f "$resolved" ]]; then
        warn "Rule file not found: $resolved"
      else
        filename="$(basename "$resolved")"
        cp "$resolved" "$project_claude_dir/rules/$filename"
        success "Rule: $filename → $project_claude_dir/rules/"
      fi
      n=$((n + 1))
    done
  fi

  echo ""
  success "Scaffold complete!"
}
