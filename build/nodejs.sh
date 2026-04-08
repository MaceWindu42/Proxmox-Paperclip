#!/usr/bin/env bash
# build/nodejs.sh — Install Node.js 20 LTS inside the LXC container
set -euo pipefail

NODE_MAJOR="${NODE_MAJOR:-20}"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$(tput setaf 1 2>/dev/null || echo "")
  GREEN=$(tput setaf 2 2>/dev/null || echo "")
  CYAN=$(tput setaf 6 2>/dev/null || echo "")
  BOLD=$(tput bold 2>/dev/null || echo "")
  RESET=$(tput sgr0 2>/dev/null || echo "")
else
  RED="" GREEN="" CYAN="" BOLD="" RESET=""
fi

msg() { echo "${CYAN}${BOLD}[nodejs]${RESET} $*"; }
ok()  { echo "${GREEN}✔${RESET} $*"; }
die() { echo "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Check if Node.js is already installed at required version
# ---------------------------------------------------------------------------
already_installed() {
  if command -v node &>/dev/null; then
    local installed_major
    installed_major=$(node --version | grep -oP '(?<=v)\d+')
    if (( installed_major >= NODE_MAJOR )); then
      ok "Node.js $(node --version) already installed, skipping."
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if already_installed; then
    return 0
  fi

  msg "Installing Node.js ${NODE_MAJOR} LTS via NodeSource..."
  export DEBIAN_FRONTEND=noninteractive

  # Download and run NodeSource setup script
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs

  # Verify
  local node_version npm_version
  node_version=$(node --version 2>/dev/null) || die "node command not found after install."
  npm_version=$(npm --version 2>/dev/null)   || die "npm command not found after install."

  ok "Node.js ${node_version} installed."
  ok "npm ${npm_version} installed."
}

main "$@"
