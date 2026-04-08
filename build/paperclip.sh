#!/usr/bin/env bash
# build/paperclip.sh — Install and configure Paperclip inside the LXC container
set -euo pipefail

PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
PAPERCLIP_STARTUP_TIMEOUT="${PAPERCLIP_STARTUP_TIMEOUT:-60}"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$(tput setaf 1 2>/dev/null || echo "")
  GREEN=$(tput setaf 2 2>/dev/null || echo "")
  YELLOW=$(tput setaf 3 2>/dev/null || echo "")
  CYAN=$(tput setaf 6 2>/dev/null || echo "")
  BOLD=$(tput bold 2>/dev/null || echo "")
  RESET=$(tput sgr0 2>/dev/null || echo "")
else
  RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

msg()  { echo "${CYAN}${BOLD}[paperclip]${RESET} $*"; }
ok()   { echo "${GREEN}✔${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET} $*"; }
die()  { echo "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verify node/npm available
# ---------------------------------------------------------------------------
check_node() {
  command -v node &>/dev/null || die "Node.js not found. Run nodejs.sh first."
  command -v npm  &>/dev/null || die "npm not found. Run nodejs.sh first."
}

# ---------------------------------------------------------------------------
# Install PM2 (idempotent)
# ---------------------------------------------------------------------------
install_pm2() {
  if command -v pm2 &>/dev/null; then
    ok "PM2 already installed ($(pm2 --version))."
  else
    msg "Installing PM2 globally..."
    npm install -g pm2 --quiet
    ok "PM2 $(pm2 --version) installed."
  fi
}

# ---------------------------------------------------------------------------
# Install Paperclip (idempotent)
# ---------------------------------------------------------------------------
install_paperclip() {
  if command -v paperclipai &>/dev/null; then
    ok "paperclipai already installed."
  else
    msg "Installing paperclipai globally..."
    npm install -g paperclipai --quiet
    ok "paperclipai installed."
  fi
  command -v paperclipai &>/dev/null || die "paperclipai command not found after install."
}

# ---------------------------------------------------------------------------
# Wait for Paperclip to start
# ---------------------------------------------------------------------------
wait_for_paperclip() {
  msg "Waiting for Paperclip to respond on port ${PAPERCLIP_PORT}..."
  local attempts=0
  local max=$(( PAPERCLIP_STARTUP_TIMEOUT / 2 ))
  while (( attempts < max )); do
    if curl -sf "http://127.0.0.1:${PAPERCLIP_PORT}/" &>/dev/null; then
      ok "Paperclip is responding."
      return 0
    fi
    (( attempts++ ))
    sleep 2
  done
  warn "Paperclip did not respond within ${PAPERCLIP_STARTUP_TIMEOUT}s (may still be starting up)."
  return 0  # Non-fatal — could be initializing
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_node
  install_pm2
  install_paperclip

  # Start Paperclip with PM2 (idempotent — delete existing process first if present)
  msg "Configuring PM2 to manage Paperclip..."
  if pm2 describe paperclip &>/dev/null; then
    msg "Paperclip process already registered in PM2. Restarting..."
    pm2 restart paperclip
  else
    # Use the full path to the paperclipai binary
    local paperclip_bin
    paperclip_bin=$(command -v paperclipai)
    pm2 start "${paperclip_bin}" \
      --name paperclip \
      --interpreter bash \
      -- start \
      2>/dev/null || pm2 start paperclipai --name paperclip
  fi

  ok "Paperclip process started under PM2."

  # Configure PM2 to start on boot
  msg "Configuring PM2 startup..."
  local pm2_startup
  pm2_startup=$(pm2 startup systemd -u root --hp /root 2>&1 | tail -1)
  # The startup command needs to be executed
  if [[ "${pm2_startup}" =~ sudo ]]; then
    eval "${pm2_startup}" 2>/dev/null || true
  fi
  pm2 save

  ok "PM2 startup configured."

  wait_for_paperclip

  # Final verification
  if pm2 list | grep -q paperclip; then
    ok "Paperclip is running under PM2."
  else
    warn "PM2 process not listed — check 'pm2 logs paperclip' for details."
  fi
}

main "$@"
