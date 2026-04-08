#!/usr/bin/env bash
# build/os-setup.sh — Base OS setup inside the LXC container
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN=$(tput setaf 2 2>/dev/null || echo "")
  CYAN=$(tput setaf 6 2>/dev/null || echo "")
  BOLD=$(tput bold 2>/dev/null || echo "")
  RESET=$(tput sgr0 2>/dev/null || echo "")
else
  GREEN="" CYAN="" BOLD="" RESET=""
fi

msg() { echo "${CYAN}${BOLD}[os-setup]${RESET} $*"; }
ok()  { echo "${GREEN}✔${RESET} $*"; }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  msg "Updating package lists and upgrading..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  ok "System updated."

  msg "Installing base packages..."
  apt-get install -y -qq \
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    systemd \
    openssl
  ok "Base packages installed."
}

main "$@"
