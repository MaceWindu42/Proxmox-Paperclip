#!/usr/bin/env bash
# build/ollama.sh — Install Ollama and pull the configured model
set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2}"
OLLAMA_PULL_TIMEOUT="${OLLAMA_PULL_TIMEOUT:-1800}"  # 30 min default

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

msg()  { echo "${CYAN}${BOLD}[ollama]${RESET} $*"; }
ok()   { echo "${GREEN}✔${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET} $*"; }
die()  { echo "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Wait for Ollama service to start
# ---------------------------------------------------------------------------
wait_for_ollama() {
  msg "Waiting for Ollama service to become ready..."
  local attempts=0
  local max=30
  while (( attempts < max )); do
    if curl -sf http://127.0.0.1:11434/ &>/dev/null; then
      ok "Ollama is responding."
      return 0
    fi
    (( attempts++ ))
    sleep 2
  done
  die "Ollama did not start within $((max * 2)) seconds."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # Idempotent: check if already installed
  if command -v ollama &>/dev/null; then
    ok "Ollama already installed ($(ollama --version 2>/dev/null || echo 'unknown version'))."
  else
    msg "Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
    ok "Ollama installed."
  fi

  # Enable and start service
  msg "Enabling and starting ollama systemd service..."
  if systemctl is-enabled ollama &>/dev/null; then
    ok "Ollama service already enabled."
  else
    systemctl enable ollama
  fi

  if systemctl is-active ollama &>/dev/null; then
    ok "Ollama service already running."
  else
    systemctl start ollama
  fi

  wait_for_ollama

  # Pull model (skip if none)
  if [[ "${OLLAMA_MODEL}" == "none" ]]; then
    warn "No model selected — skipping model download."
    return 0
  fi

  msg "Pulling Ollama model: ${BOLD}${OLLAMA_MODEL}${RESET}"
  msg "(This may take several minutes depending on model size and network speed...)"

  # Run pull with timeout
  if timeout "${OLLAMA_PULL_TIMEOUT}" ollama pull "${OLLAMA_MODEL}"; then
    ok "Model '${OLLAMA_MODEL}' pulled successfully."
  else
    die "Failed to pull model '${OLLAMA_MODEL}' within ${OLLAMA_PULL_TIMEOUT}s. Check network and try again."
  fi

  # Verify model is listed
  if ollama list | grep -q "${OLLAMA_MODEL}"; then
    ok "Model '${OLLAMA_MODEL}' verified in local library."
  else
    warn "Model pulled but not found in 'ollama list'. Installation may still be functional."
  fi
}

main "$@"
