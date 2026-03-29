#!/usr/bin/env bash
set -euo pipefail

# ── Termcast server installer ─────────────────────────────────────
# Supports: macOS (arm64, x64), Linux (x64, arm64), WSL
#
#   curl -fsSL https://ttyd-relay.xing-mathcoder.workers.dev/install.sh | bash
#
# ──────────────────────────────────────────────────────────────────

INSTALL_DIR="$HOME/.termcast"
BASE_URL="https://ttyd-relay.xing-mathcoder.workers.dev"
NODE_VERSION="22.14.0"

# ── Colors ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "  ${CYAN}$*${NC}"; }
ok()    { echo -e "  ${GREEN}$*${NC}"; }
warn()  { echo -e "  ${YELLOW}$*${NC}"; }
fail()  { echo -e "  ${RED}error: $*${NC}" >&2; exit 1; }
step()  { echo -e "  ${DIM}[$1/$TOTAL_STEPS]${NC} $2"; }

# ── Detect platform ──────────────────────────────────────────────
detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Linux)   PLATFORM="linux" ;;
    Darwin)  PLATFORM="darwin" ;;
    MINGW*|MSYS*|CYGWIN*)
      fail "Windows is not supported. Use WSL instead:
       wsl --install
       Then run this installer inside WSL." ;;
    *)       fail "Unsupported OS: $OS" ;;
  esac

  case "$ARCH" in
    x86_64|amd64)   NODE_ARCH="x64" ;;
    aarch64|arm64)   NODE_ARCH="arm64" ;;
    armv7l|armv6l)
      fail "32-bit ARM is not supported. Use a 64-bit OS." ;;
    *)
      fail "Unsupported architecture: $ARCH" ;;
  esac

  # Detect WSL
  IS_WSL=false
  if [ "$PLATFORM" = "linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
  fi
}

# ── Check / install Node.js ──────────────────────────────────────
ensure_node() {
  # Check existing Node.js
  if command -v node &>/dev/null; then
    NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 18 ]; then
      NODE_BIN="$(command -v node)"
      NPM_BIN="$(command -v npm)"
      return
    fi
    warn "Node.js $(node -v) found but v18+ required. Installing bundled Node.js..."
  fi

  # Install Node.js locally
  step "$CURRENT_STEP" "Installing Node.js ${NODE_VERSION}..."

  local NODE_DIR="$INSTALL_DIR/node"
  local NODE_DIST

  case "$PLATFORM" in
    darwin) NODE_DIST="node-v${NODE_VERSION}-darwin-${NODE_ARCH}" ;;
    linux)  NODE_DIST="node-v${NODE_VERSION}-linux-${NODE_ARCH}" ;;
  esac

  local NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIST}.tar.xz"

  mkdir -p "$NODE_DIR"

  # Try tar.xz first (smaller), fall back to tar.gz
  if command -v xz &>/dev/null; then
    curl -fsSL "$NODE_URL" < /dev/null | tar xJ -C "$NODE_DIR" --strip-components=1
  else
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIST}.tar.gz"
    curl -fsSL "$NODE_URL" < /dev/null | tar xz -C "$NODE_DIR" --strip-components=1
  fi

  NODE_BIN="$NODE_DIR/bin/node"
  NPM_BIN="$NODE_DIR/bin/npm"
  export PATH="$NODE_DIR/bin:$PATH"

  if [ ! -x "$NODE_BIN" ]; then
    fail "Failed to install Node.js. Download manually from https://nodejs.org"
  fi

  ok "Node.js $("$NODE_BIN" -v) installed"
  BUNDLED_NODE=true
}

# ── Download server ───────────────────────────────────────────────
download_server() {
  step "$CURRENT_STEP" "Downloading Termcast server..."

  mkdir -p "$INSTALL_DIR/bin"

  local TARBALL_URL="$BASE_URL/releases/latest.tar.gz"
  if ! curl -fsSL "$TARBALL_URL" < /dev/null | tar xz -C "$INSTALL_DIR"; then
    fail "Failed to download Termcast server"
  fi

  ok "Termcast server downloaded"
}

# ── Install npm dependencies ─────────────────────────────────────
install_deps() {
  step "$CURRENT_STEP" "Installing dependencies..."

  cd "$INSTALL_DIR"
  "$NPM_BIN" install --production --silent < /dev/null 2>/dev/null

  ok "Dependencies installed"
}

# ── Download ttyd binary ──────────────────────────────────────────
TTYD_VERSION="1.7.7"

download_binary() {
  step "$CURRENT_STEP" "Downloading ttyd ${TTYD_VERSION}..."

  # The server runtime looks for ttyd-{platform}-{arch}
  local BIN_KEY="ttyd-${PLATFORM}-${NODE_ARCH}"
  local BIN_DEST="$INSTALL_DIR/bin/${BIN_KEY}"

  local GH_FILE=""
  case "${PLATFORM}-${NODE_ARCH}" in
    linux-x64)    GH_FILE="ttyd.x86_64" ;;
    linux-arm64)  GH_FILE="ttyd.aarch64" ;;
    darwin-arm64) GH_FILE="ttyd.universal" ;;
    darwin-x64)   GH_FILE="ttyd.universal" ;;
  esac

  if [ -z "$GH_FILE" ]; then
    warn "ttyd binary not available for ${PLATFORM}-${NODE_ARCH}"
    warn "Install manually: https://github.com/tsl0922/ttyd/releases"
    return
  fi

  local GH_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${GH_FILE}"
  if curl -fsSL "$GH_URL" -o "$BIN_DEST" < /dev/null 2>/dev/null && [ -s "$BIN_DEST" ]; then
    chmod +x "$BIN_DEST"
    ok "ttyd ${TTYD_VERSION} installed"
  else
    warn "Failed to download ttyd ${TTYD_VERSION}"
    warn "Install manually: https://github.com/tsl0922/ttyd/releases"
  fi
}

# ── Create wrapper script ────────────────────────────────────────
create_wrapper() {
  step "$CURRENT_STEP" "Creating termcast command..."

  # Determine node path for wrapper
  local NODE_PATH
  if [ "${BUNDLED_NODE:-false}" = true ]; then
    NODE_PATH="\$HOME/.termcast/node/bin/node"
  else
    NODE_PATH="$(command -v node)"
  fi

  cat > "$INSTALL_DIR/bin/termcast" << 'WRAPPER'
#!/usr/bin/env bash
NODE_PATH="NODE_PATH_PLACEHOLDER"
SCRIPT="$HOME/.termcast/dist/index.js"
LOG="$HOME/.termcast/termcast.log"

case "${1:-}" in
  start)
    shift
    nohup "$NODE_PATH" "$SCRIPT" start "$@" > "$LOG" 2>&1 &
    disown
    PID=$!
    echo "$PID" > "$HOME/.termcast/termcast.pid"
    echo "Termcast server started (pid $PID)"
    echo "Logs: $LOG"
    # Wait briefly and show QR info from log
    sleep 2
    grep -A1 'Web UI\|Scan\|QR' "$LOG" 2>/dev/null || true
    ;;
  stop)
    if [ -f "$HOME/.termcast/termcast.pid" ]; then
      PID=$(cat "$HOME/.termcast/termcast.pid")
      kill "$PID" 2>/dev/null && echo "Termcast server stopped (pid $PID)" || echo "Server not running"
      rm -f "$HOME/.termcast/termcast.pid"
    else
      echo "No running server found"
    fi
    ;;
  logs)
    tail -f "$LOG"
    ;;
  *)
    exec "$NODE_PATH" "$SCRIPT" "$@"
    ;;
esac
WRAPPER

  # Replace placeholder with actual node path
  sed -i.bak "s|NODE_PATH_PLACEHOLDER|$NODE_PATH|" "$INSTALL_DIR/bin/termcast"
  rm -f "$INSTALL_DIR/bin/termcast.bak"
  chmod +x "$INSTALL_DIR/bin/termcast"
}

# ── Add to PATH ──────────────────────────────────────────────────
setup_path() {
  local PATH_LINE='export PATH="$HOME/.termcast/bin:$PATH"'
  local ADDED_FILES=""

  add_to_rc() {
    local rc="$1"
    if [ -f "$rc" ] && grep -q '.termcast/bin' "$rc" 2>/dev/null; then
      return
    fi
    printf '\n# termcast\n%s\n' "$PATH_LINE" >> "$rc"
    ADDED_FILES="${ADDED_FILES} ${rc/$HOME/~}"
  }

  # Add to all common shell RC files so it works everywhere
  # bash
  if [ -f "$HOME/.bashrc" ]; then
    add_to_rc "$HOME/.bashrc"
  fi
  if [ -f "$HOME/.bash_profile" ]; then
    add_to_rc "$HOME/.bash_profile"
  fi
  # zsh
  add_to_rc "$HOME/.zshrc"
  # POSIX fallback
  if [ -f "$HOME/.profile" ]; then
    add_to_rc "$HOME/.profile"
  fi
  # fish
  if command -v fish &>/dev/null; then
    local FISH_RC="$HOME/.config/fish/config.fish"
    mkdir -p "$(dirname "$FISH_RC")"
    if ! grep -q '.termcast/bin' "$FISH_RC" 2>/dev/null; then
      printf '\n# termcast\nset -gx PATH $HOME/.termcast/bin $PATH\n' >> "$FISH_RC"
      ADDED_FILES="${ADDED_FILES} ${FISH_RC/$HOME/~}"
    fi
  fi

  if [ -n "$ADDED_FILES" ]; then
    info "Added to PATH in:${ADDED_FILES}"
  fi
}

# ── Main ─────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "  ${BOLD}Termcast${NC} installer"
  echo -e "  ${DIM}Access your terminal from anywhere${NC}"
  echo ""

  detect_platform

  local PLATFORM_LABEL="$PLATFORM-$NODE_ARCH"
  if [ "$IS_WSL" = true ]; then
    PLATFORM_LABEL="$PLATFORM_LABEL (WSL)"
  fi
  info "Platform: $PLATFORM_LABEL"
  echo ""

  # Count steps
  BUNDLED_NODE=false
  TOTAL_STEPS=5
  if ! command -v node &>/dev/null || [ "$(node -v | sed 's/v//' | cut -d. -f1)" -lt 18 ] 2>/dev/null; then
    TOTAL_STEPS=6
  fi

  CURRENT_STEP=1

  # Step 1 (optional): Install Node.js
  ensure_node
  if [ "${BUNDLED_NODE}" = true ]; then
    CURRENT_STEP=$((CURRENT_STEP + 1))
  fi

  # Step 2: Download server
  CURRENT_STEP=$((CURRENT_STEP + 1))
  download_server

  # Step 3: Install deps
  CURRENT_STEP=$((CURRENT_STEP + 1))
  install_deps

  # Step 4: Download binary
  CURRENT_STEP=$((CURRENT_STEP + 1))
  download_binary

  # Step 5: Create wrapper + PATH
  CURRENT_STEP=$((CURRENT_STEP + 1))
  create_wrapper
  setup_path

  # Add to PATH for the current session
  export PATH="$INSTALL_DIR/bin:$PATH"

  # Done
  echo ""
  echo -e "  ${GREEN}${BOLD}Termcast installed successfully!${NC}"
  echo ""
  echo -e "  Commands:"
  echo -e "    ${CYAN}termcast start${NC}     Start server in background (survives shell exit)"
  echo -e "    ${CYAN}termcast stop${NC}      Stop the running server"
  echo -e "    ${CYAN}termcast logs${NC}      View server logs"
  echo -e "    ${CYAN}termcast qr${NC}        Regenerate QR code"
  echo ""
  if [ "$IS_WSL" = true ]; then
    echo -e "  ${DIM}Tip: In WSL, scan the QR code from the terminal or open${NC}"
    echo -e "  ${DIM}http://localhost:8080 in your Windows browser.${NC}"
    echo ""
  fi
  echo -e "  ${YELLOW}To activate in this terminal, run:${NC}"
  echo ""
  echo -e "    ${CYAN}source ~/.bashrc${NC}    ${DIM}# or: source ~/.zshrc${NC}"
  echo ""
  echo -e "  ${DIM}Then run 'termcast start' to get started.${NC}"
  echo ""
}

main
