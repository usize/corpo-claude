#!/usr/bin/env bash
# lib/profiles.sh — Profile loading, merging, validation
#
# Profiles are directory-based: profiles/<name>/profile.yaml
# All file references inside a profile are relative to its directory.
# Before merging, paths are absolutized so the merged result works
# regardless of where profiles came from.

# ── List available profiles ────────────────────────────────────

# Prints profile names (directory names containing profile.yaml), one per line
list_profiles() {
  local profiles_dir
  profiles_dir="$(resolve_path "profiles")"

  if [[ ! -d "$profiles_dir" ]]; then
    error "Profiles directory not found: $profiles_dir"
    return 1
  fi

  local found=0
  for d in "$profiles_dir"/*/; do
    [[ -d "$d" ]] || continue
    if [[ -f "$d/profile.yaml" ]] || [[ -f "$d/profile.yml" ]]; then
      basename "$d"
      found=1
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    error "No profiles found in $profiles_dir"
    return 1
  fi
}

# ── Load a single profile ─────────────────────────────────────

# Finds and prints the path to a profile.yaml by profile name.
# Searches local profiles first, then registries if available.
resolve_profile_path() {
  local name="$1"
  local profiles_dir
  profiles_dir="$(resolve_path "profiles")"

  # Check local directory-based profile
  for ext in yaml yml; do
    local path="$profiles_dir/$name/profile.$ext"
    if [[ -f "$path" ]]; then
      echo "$path"
      return 0
    fi
  done

  # Check remote registries (downloads profile directory to temp)
  if command -v find_profile &>/dev/null 2>&1; then
    local profile_info
    profile_info="$(find_profile "$name" 2>/dev/null)" || true
    if [[ -n "$profile_info" ]]; then
      local registry
      registry="$(echo "$profile_info" | jq -r '.registry')"
      if [[ "$registry" != "local" ]]; then
        local downloaded_dir
        downloaded_dir="$(download_remote_profile "$name" "$registry")" || {
          error "Failed to download profile $name from $registry"
          return 1
        }
        # Return the profile.yaml inside the downloaded directory
        for ext in yaml yml; do
          if [[ -f "$downloaded_dir/profile.$ext" ]]; then
            echo "$downloaded_dir/profile.$ext"
            return 0
          fi
        done
      fi
    fi
  fi

  error "Profile not found: $name"
  return 1
}

# Returns the directory containing a profile.yaml file
profile_dir() {
  local profile_path="$1"
  dirname "$profile_path"
}

# ── Absolutize profile paths ──────────────────────────────────

# Takes a profile.yaml path and returns a temp copy with all
# relative file references resolved to absolute paths based on
# the profile's directory. This allows merging profiles from
# different locations.
_absolutize_profile_paths() {
  local profile_file="$1"
  local base_dir
  base_dir="$(profile_dir "$profile_file")"

  local tmp
  tmp="$(mktemp)"
  cp "$profile_file" "$tmp"

  # Helper: resolve a single field if it's a non-empty relative path
  _abs_field() {
    local field="$1"
    local val
    val="$(yq eval "$field // \"\"" "$tmp")"
    if [[ -n "$val" && "$val" != "null" && "$val" != /* ]]; then
      yq eval -i "$field = \"$base_dir/$val\"" "$tmp"
    fi
  }

  # Helper: resolve each element of an array field
  _abs_array() {
    local field="$1"
    local count
    count="$(yq eval "$field | length" "$tmp")"
    if [[ "$count" != "0" && "$count" != "null" ]]; then
      local i=0
      while [[ $i -lt $count ]]; do
        local val
        val="$(yq eval "${field}[$i]" "$tmp")"
        if [[ -n "$val" && "$val" != "null" && "$val" != /* ]]; then
          yq eval -i "${field}[$i] = \"$base_dir/$val\"" "$tmp"
        fi
        i=$((i + 1))
      done
    fi
  }

  # Absolutize known path fields
  _abs_field ".claude_md"
  _abs_array ".skills"
  _abs_field ".project_template.claude_md"
  _abs_array ".project_template.commands"
  _abs_array ".project_template.rules"

  echo "$tmp"
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
# All file paths are absolutized before merging so the result
# works regardless of where each profile came from.
# Result is written to a temp file; path printed to stdout.
merge_profiles() {
  local profile_names=("$@")

  if [[ ${#profile_names[@]} -eq 0 ]]; then
    error "No profiles specified."
    return 1
  fi

  local tmpfile
  tmpfile="$(mktemp)"

  # Start with the first profile (absolutized)
  local first_path first_abs
  first_path="$(resolve_profile_path "${profile_names[0]}")" || return 1
  first_abs="$(_absolutize_profile_paths "$first_path")"
  cp "$first_abs" "$tmpfile"
  rm -f "$first_abs"

  # Merge remaining profiles using file-based operations
  for ((i = 1; i < ${#profile_names[@]}; i++)); do
    local path abs_path prev
    path="$(resolve_profile_path "${profile_names[$i]}")" || return 1
    abs_path="$(_absolutize_profile_paths "$path")"
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
    ' "$prev" "$abs_path" > "$tmpfile"
    rm -f "$prev" "$abs_path"
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
