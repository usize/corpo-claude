#!/usr/bin/env bash
# lib/profiles.sh — Profile loading, merging, validation

# ── List available profiles ────────────────────────────────────

# Prints profile names (without .yaml extension), one per line
list_profiles() {
  local profiles_dir
  profiles_dir="$(resolve_path "profiles")"

  if [[ ! -d "$profiles_dir" ]]; then
    error "Profiles directory not found: $profiles_dir"
    return 1
  fi

  local found=0
  for f in "$profiles_dir"/*.yaml "$profiles_dir"/*.yml; do
    [[ -f "$f" ]] || continue
    basename "$f" | sed 's/\.\(yaml\|yml\)$//'
    found=1
  done

  if [[ "$found" -eq 0 ]]; then
    error "No profiles found in $profiles_dir"
    return 1
  fi
}

# ── Load a single profile ─────────────────────────────────────

# Finds and prints the path to a profile file by name
resolve_profile_path() {
  local name="$1"
  local profiles_dir
  profiles_dir="$(resolve_path "profiles")"

  for ext in yaml yml; do
    local path="$profiles_dir/$name.$ext"
    if [[ -f "$path" ]]; then
      echo "$path"
      return 0
    fi
  done

  error "Profile not found: $name"
  return 1
}

# ── Parse --profile flags from CLI args ────────────────────────

# Sets SELECTED_PROFILES array and REMAINING_ARGS array
SELECTED_PROFILES=()
REMAINING_ARGS=()

parse_profile_flags() {
  SELECTED_PROFILES=()
  REMAINING_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        if [[ -z "${2:-}" ]]; then
          error "--profile requires a name argument"
          return 1
        fi
        SELECTED_PROFILES+=("$2")
        shift 2
        ;;
      *)
        REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# Interactive multi-select profile picker.
# Call after parse_profile_flags; if SELECTED_PROFILES is empty,
# presents a gum choose menu and populates SELECTED_PROFILES.
select_profiles_interactive() {
  if [[ ${#SELECTED_PROFILES[@]} -gt 0 ]]; then
    return 0
  fi

  local available
  available="$(list_profiles)" || return 1

  local count
  count="$(echo "$available" | wc -l | tr -d ' ')"

  if [[ "$count" -eq 0 ]]; then
    error "No profiles available."
    return 1
  fi

  info "No --profile flag given. Select profile(s) to apply:"
  echo ""

  local chosen
  chosen="$(echo "$available" | gum choose --no-limit --header "Select profiles (space to toggle, enter to confirm)")"

  if [[ -z "$chosen" ]]; then
    error "No profiles selected."
    return 1
  fi

  while IFS= read -r profile; do
    SELECTED_PROFILES+=("$profile")
  done <<< "$chosen"
}

# ── Merge multiple profiles ───────────────────────────────────

# Merges profile YAML files into a single combined profile.
# Arrays are accumulated, scalars are last-wins.
# Result is written to a temp file; path printed to stdout.
merge_profiles() {
  local profile_names=("$@")

  if [[ ${#profile_names[@]} -eq 0 ]]; then
    error "No profiles specified."
    return 1
  fi

  local tmpfile
  tmpfile="$(mktemp)"

  # Start with the first profile
  local first_path
  first_path="$(resolve_profile_path "${profile_names[0]}")" || return 1
  cp "$first_path" "$tmpfile"

  # Merge remaining profiles using file-based operations
  for ((i = 1; i < ${#profile_names[@]}; i++)); do
    local path prev
    path="$(resolve_profile_path "${profile_names[$i]}")" || return 1
    prev="$(mktemp)"
    cp "$tmpfile" "$prev"
    yq eval-all '
      def merge_deep(a; b):
        a as $a | b as $b |
        if ($a | type) == "object" and ($b | type) == "object" then
          ($a | keys) + ($b | keys) | unique | .[] as $k |
          { ($k): merge_deep($a[$k]; $b[$k]) } | add // {}
        elif ($a | type) == "array" and ($b | type) == "array" then
          $a + $b
        elif $b != null then
          $b
        else
          $a
        end;
      merge_deep(.[0]; .[1])
    ' "$prev" "$path" > "$tmpfile"
    rm -f "$prev"
  done

  echo "$tmpfile"
}

# ── Read merged profile fields ─────────────────────────────────

# Convenience: read a field from a merged profile file
profile_get() {
  local profile_file="$1"
  local query="$2"
  yq eval "$query" "$profile_file"
}

# Check if a field exists and is not null
profile_has() {
  local profile_file="$1"
  local query="$2"
  local val
  val="$(yq eval "$query" "$profile_file")"
  [[ -n "$val" && "$val" != "null" ]]
}
