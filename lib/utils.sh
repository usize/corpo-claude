#!/usr/bin/env bash
# lib/utils.sh — Shared helpers for corpo-claude

# Resolve the repo root (directory containing the corpo-claude script)
CORPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Version
CORPO_VERSION="0.2.0"

# Data directory for corpo-claude state (registries, installed skills, cache)
CORPO_DATA_DIR="${CORPO_DATA_DIR:-$HOME/.corpo-claude}"

# ── Styled output ──────────────────────────────────────────────
# All output helpers fall back to plain text if gum is not installed,
# so that dependency checks can report errors before gum is available.

_has_gum() {
  command -v gum &>/dev/null
}

info() {
  if _has_gum; then
    gum style --foreground 39 "ℹ $*"
  else
    echo "ℹ $*"
  fi
}

warn() {
  if _has_gum; then
    gum style --foreground 214 "⚠ $*"
  else
    echo "⚠ $*" >&2
  fi
}

error() {
  if _has_gum; then
    gum style --foreground 196 "✖ $*" >&2
  else
    echo "✖ $*" >&2
  fi
}

success() {
  if _has_gum; then
    gum style --foreground 76 "✔ $*"
  else
    echo "✔ $*"
  fi
}

header() {
  if _has_gum; then
    gum style --bold --border double --padding "0 2" --border-foreground 39 "$*"
  else
    echo "═══ $* ═══"
  fi
}

# ── Dependency checks ─────────────────────────────────────────

check_dependency() {
  local cmd="$1"
  local install_hint="$2"

  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd is required but not installed."
    if [[ -n "$install_hint" ]]; then
      if _has_gum; then
        gum style --foreground 250 "  Install: $install_hint"
      else
        echo "  Install: $install_hint"
      fi
    fi
    return 1
  fi
  return 0
}

check_all_dependencies() {
  local missing=0

  check_dependency "gum" "brew install gum  (https://github.com/charmbracelet/gum)" || missing=1
  check_dependency "yq" "brew install yq  (https://github.com/mikefarah/yq)" || missing=1
  check_dependency "jq" "brew install jq  (https://github.com/jqlang/jq)" || missing=1

  if [[ "$missing" -eq 1 ]]; then
    echo ""
    error "Please install missing dependencies and try again."
    exit 1
  fi
}

# ── Data directory ─────────────────────────────────────────

ensure_data_dir() {
  mkdir -p "$CORPO_DATA_DIR"
  mkdir -p "$CORPO_DATA_DIR/cache"
}

# ── Skills dependency check ───────────────────────────────

# Checks for gh CLI, required by skill install/search from remote registries.
# Returns 0 if gh is available, 1 otherwise.
check_skills_dependencies() {
  check_dependency "gh" "brew install gh  (https://cli.github.com/)" || return 1
  return 0
}

# ── Sandbox dependency check ──────────────────────────────────

# Checks for Docker, required by fork commands.
# Returns 0 if docker is available, 1 otherwise.
check_sandbox_dependencies() {
  check_dependency "docker" "brew install --cask docker  (https://www.docker.com/products/docker-desktop/)" || return 1
  return 0
}

# ── Path helpers ───────────────────────────────────────────────

# Resolve a path relative to the corpo-claude repo root.
# If the path is already absolute, return it as-is.
resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    echo "$path"
  else
    echo "$CORPO_ROOT/$path"
  fi
}

# ── Auth validation ────────────────────────────────────────────

# Validates cloud provider authentication. Warns (does not fail)
# if credentials are not configured.
validate_auth() {
  local provider_type="$1"

  case "$provider_type" in
    vertex)
      info "Checking Vertex AI (GCP) authentication..."
      if ! command -v gcloud &>/dev/null; then
        warn "gcloud CLI is not installed. Install it from https://cloud.google.com/sdk/docs/install"
        warn "Then run: gcloud auth application-default login"
        return 0
      fi
      if gcloud auth application-default print-access-token &>/dev/null 2>&1; then
        success "GCP application-default credentials are configured."
      else
        warn "GCP application-default credentials not found."
        warn "Run: gcloud auth application-default login"
      fi
      ;;
    bedrock)
      info "Checking AWS authentication..."
      if ! command -v aws &>/dev/null; then
        warn "AWS CLI is not installed. Install it from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        return 0
      fi
      if aws sts get-caller-identity &>/dev/null 2>&1; then
        success "AWS credentials are configured."
      else
        warn "AWS credentials not found or expired."
        warn "Run: aws configure  or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
      fi
      ;;
  esac
}
