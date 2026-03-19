#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/mofoster/corpo-claude.git"
INSTALL_DIR="$HOME/.corpo-claude/repo"
BIN_DIR="$HOME/.local/bin"
BIN_LINK="$BIN_DIR/corpo-claude"

# ── Colors ────────────────────────────────────────────────────

if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
  BLUE='\033[0;34m' BOLD='\033[1m' RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info()  { printf "${BLUE}${BOLD}::${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}${BOLD}ok${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}${BOLD}warn${RESET} %s\n" "$*"; }
err()   { printf "${RED}${BOLD}error${RESET} %s\n" "$*" >&2; }

# ── Uninstall ─────────────────────────────────────────────────

uninstall() {
  info "Uninstalling corpo-claude..."

  if [ -L "$BIN_LINK" ]; then
    rm "$BIN_LINK"
    ok "Removed symlink $BIN_LINK"
  fi

  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    ok "Removed $INSTALL_DIR"
  fi

  # Remove parent dir if empty
  rmdir "$HOME/.corpo-claude" 2>/dev/null || true

  ok "corpo-claude has been uninstalled."
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall ;;
    *) err "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Dependency checks ────────────────────────────────────────

info "Checking dependencies..."

if ! command -v git >/dev/null 2>&1; then
  err "git is required but not installed. Please install git first."
  exit 1
fi
ok "git"

for tool in gum yq jq gh; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool"
  else
    warn "$tool not found (optional — some features may be limited)"
  fi
done

# ── Clone or update repo ─────────────────────────────────────

if [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating corpo-claude..."
  git -C "$INSTALL_DIR" pull --ff-only --quiet
  ok "Updated to latest version."
else
  info "Cloning corpo-claude..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
  ok "Cloned to $INSTALL_DIR"
fi

# ── Symlink executable ───────────────────────────────────────

mkdir -p "$BIN_DIR"

if [ -L "$BIN_LINK" ]; then
  rm "$BIN_LINK"
fi

ln -s "$INSTALL_DIR/corpo-claude" "$BIN_LINK"
chmod +x "$INSTALL_DIR/corpo-claude"
ok "Linked corpo-claude -> $BIN_LINK"

# ── Success ──────────────────────────────────────────────────

echo ""
printf "${GREEN}${BOLD}corpo-claude installed successfully!${RESET}\n"
echo ""

case ":${PATH}:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not in your PATH."
    echo ""
    echo "  Add it by appending this to your shell profile:"
    echo ""
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    ;;
esac

info "Get started:"
echo ""
echo "  corpo-claude skill search     Search for skills"
echo "  corpo-claude profile init     Initialize a profile"
echo "  corpo-claude --help           Show all commands"
echo ""
