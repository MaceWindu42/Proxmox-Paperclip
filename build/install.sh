#!/usr/bin/env bash
# build/install.sh — Container bootstrap orchestrator
# Executed inside the LXC container after creation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

msg()  { echo "${CYAN}${BOLD}[install]${RESET} $*"; }
ok()   { echo "${GREEN}✔${RESET} $*"; }
die()  { echo "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Environment defaults (passed from ct/paperclip.sh via env vars)
# ---------------------------------------------------------------------------
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2}"
ENABLE_NGINX="${ENABLE_NGINX:-N}"

# ---------------------------------------------------------------------------
# Run sub-modules
# ---------------------------------------------------------------------------
run_module() {
  local name="$1"
  local script="${SCRIPT_DIR}/${name}"
  if [[ ! -f "${script}" ]]; then
    die "Module script not found: ${script}"
  fi
  msg "Running module: ${name}"
  bash "${script}"
  ok "Module complete: ${name}"
}

main() {
  msg "Starting Paperclip container bootstrap"
  echo "  Ollama model : ${BOLD}${OLLAMA_MODEL}${RESET}"
  echo "  Enable nginx : ${BOLD}${ENABLE_NGINX}${RESET}"
  echo

  export OLLAMA_MODEL
  export ENABLE_NGINX

  run_module "os-setup.sh"
  run_module "nodejs.sh"
  run_module "ollama.sh"
  run_module "paperclip.sh"

  if [[ "${ENABLE_NGINX}" =~ ^[Yy] ]]; then
    run_module "nginx.sh"
  else
    msg "Skipping nginx (HTTPS not selected)."
  fi

  echo
  ok "All modules completed successfully."
}

main "$@"
