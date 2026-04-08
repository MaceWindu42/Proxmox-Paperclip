#!/usr/bin/env bash
# ct/paperclip.sh — Proxmox LXC installer for Paperclip
# Usage: bash -c "$(wget -qLO - https://raw.githubusercontent.com/${GITHUB_ORG}/proxmox-paperclip/main/ct/paperclip.sh)"
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override with env vars for non-interactive mode
# ---------------------------------------------------------------------------
GITHUB_ORG="${GITHUB_ORG:-proxmox-paperclip}"
GITHUB_REPO="${GITHUB_REPO:-proxmox-paperclip}"
SCRIPT_BASE="https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/main"

CT_ID="${PAPERCLIP_CT_ID:-}"
CT_HOSTNAME="${PAPERCLIP_HOSTNAME:-paperclip}"
CT_CORES="${PAPERCLIP_CORES:-4}"
CT_MEMORY="${PAPERCLIP_MEMORY:-8192}"
CT_DISK="${PAPERCLIP_DISK:-40}"
CT_NET="${PAPERCLIP_NET:-dhcp}"
CT_IP="${PAPERCLIP_IP:-}"
CT_GW="${PAPERCLIP_GW:-}"
OLLAMA_MODEL="${PAPERCLIP_MODEL:-llama3.2}"
CT_PASSWORD="${PAPERCLIP_PASSWORD:-}"
ENABLE_NGINX="${PAPERCLIP_NGINX:-N}"
UBUNTU_TEMPLATE_STORAGE="${PAPERCLIP_TEMPLATE_STORAGE:-local}"
CT_STORAGE="${PAPERCLIP_CT_STORAGE:-local-lvm}"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

msg()    { echo "${CYAN}${BOLD}[Paperclip]${RESET} $*"; }
ok()     { echo "${GREEN}✔${RESET} $*"; }
warn()   { echo "${YELLOW}⚠${RESET} $*"; }
die()    { echo "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# PVE version guard
# ---------------------------------------------------------------------------
check_pve_version() {
  if [[ ! -f /etc/pve/local/pve-ssl.pem ]]; then
    die "This script must be run on a Proxmox VE host."
  fi
  local pve_version
  pve_version=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+' || echo "0")
  if (( pve_version < 8 )); then
    die "Proxmox VE 8.0 or later is required (detected: ${pve_version}.x). Please upgrade."
  fi
  ok "Proxmox VE ${pve_version}.x detected."
}

# ---------------------------------------------------------------------------
# Auto-detect next available CT ID
# ---------------------------------------------------------------------------
next_ct_id() {
  local id=100
  while pct status "${id}" &>/dev/null 2>&1; do
    (( id++ ))
  done
  echo "${id}"
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local current="${!var_name:-}"

  if [[ -n "${current}" ]]; then
    echo "  ${prompt_text}: ${BOLD}${current}${RESET} (from env)"
    return
  fi

  local input
  read -r -p "  ${prompt_text} [${BOLD}${default}${RESET}]: " input
  printf -v "${var_name}" '%s' "${input:-${default}}"
}

prompt_password() {
  local var_name="$1"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    echo "  Admin password: ${BOLD}(from env)${RESET}"
    return
  fi
  local pass1 pass2
  while true; do
    read -r -s -p "  Admin password: " pass1
    echo
    read -r -s -p "  Confirm password: " pass2
    echo
    if [[ "${pass1}" == "${pass2}" && -n "${pass1}" ]]; then
      printf -v "${var_name}" '%s' "${pass1}"
      break
    fi
    warn "Passwords do not match or are empty. Try again."
  done
}

prompt_model() {
  local var_name="$1"
  local current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    echo "  AI model: ${BOLD}${current}${RESET} (from env)"
    return
  fi
  echo
  echo "  Select Ollama model to pull:"
  echo "    1) llama3.2 (default)"
  echo "    2) mistral"
  echo "    3) phi3"
  echo "    4) custom (enter manually)"
  echo "    5) none (skip model download)"
  local choice
  read -r -p "  Choice [1]: " choice
  case "${choice:-1}" in
    1) printf -v "${var_name}" '%s' "llama3.2" ;;
    2) printf -v "${var_name}" '%s' "mistral" ;;
    3) printf -v "${var_name}" '%s' "phi3" ;;
    4)
      local custom_model
      read -r -p "  Enter model name: " custom_model
      printf -v "${var_name}" '%s' "${custom_model}"
      ;;
    5) printf -v "${var_name}" '%s' "none" ;;
    *) printf -v "${var_name}" '%s' "llama3.2" ;;
  esac
}

prompt_network() {
  local net_var="$1"
  local ip_var="$2"
  local gw_var="$3"
  local current="${!net_var:-}"
  if [[ -n "${current}" ]]; then
    echo "  Network: ${BOLD}${current}${RESET} (from env)"
    return
  fi
  local choice
  read -r -p "  Network [${BOLD}dhcp${RESET}/static]: " choice
  choice="${choice:-dhcp}"
  if [[ "${choice}" == "static" ]]; then
    printf -v "${net_var}" '%s' "static"
    read -r -p "  Static IP (CIDR, e.g. 192.168.1.100/24): " ip_input
    printf -v "${ip_var}" '%s' "${ip_input}"
    read -r -p "  Gateway (e.g. 192.168.1.1): " gw_input
    printf -v "${gw_var}" '%s' "${gw_input}"
  else
    printf -v "${net_var}" '%s' "dhcp"
  fi
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------
gather_config() {
  echo
  echo "${BOLD}${CYAN}===  Paperclip LXC Installer  ===${RESET}"
  echo

  [[ -z "${CT_ID}" ]] && CT_ID="$(next_ct_id)"
  prompt CT_ID        "Container ID"          "${CT_ID}"
  prompt CT_HOSTNAME  "Hostname"              "paperclip"
  prompt CT_CORES     "CPU cores"             "4"
  prompt CT_MEMORY    "RAM (MB)"              "8192"
  prompt CT_DISK      "Disk size (GB)"        "40"
  prompt_network CT_NET CT_IP CT_GW
  prompt_model OLLAMA_MODEL
  prompt_password CT_PASSWORD
  local nginx_input="${ENABLE_NGINX}"
  if [[ -z "${nginx_input}" ]]; then
    read -r -p "  Enable HTTPS via nginx? [y/${BOLD}N${RESET}]: " nginx_input
  fi
  ENABLE_NGINX="${nginx_input:-N}"
}

# ---------------------------------------------------------------------------
# Pre-flight summary
# ---------------------------------------------------------------------------
show_summary() {
  echo
  echo "${BOLD}${CYAN}=== Pre-flight Summary ===${RESET}"
  echo "  Container ID : ${BOLD}${CT_ID}${RESET}"
  echo "  Hostname     : ${BOLD}${CT_HOSTNAME}${RESET}"
  echo "  CPU          : ${BOLD}${CT_CORES}${RESET} cores"
  echo "  RAM          : ${BOLD}${CT_MEMORY}${RESET} MB"
  echo "  Disk         : ${BOLD}${CT_DISK}${RESET} GB"
  if [[ "${CT_NET}" == "static" ]]; then
    echo "  Network      : static ${BOLD}${CT_IP}${RESET} (gw: ${CT_GW})"
  else
    echo "  Network      : ${BOLD}DHCP${RESET}"
  fi
  echo "  Ollama model : ${BOLD}${OLLAMA_MODEL}${RESET}"
  echo "  HTTPS/nginx  : ${BOLD}${ENABLE_NGINX}${RESET}"
  echo
  local confirm
  # Skip confirmation in non-interactive mode
  if [[ -t 0 ]]; then
    read -r -p "Proceed with installation? [${BOLD}Y${RESET}/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Nn] ]] && { msg "Aborted."; exit 0; }
  fi
}

# ---------------------------------------------------------------------------
# Download Ubuntu 22.04 template if needed
# ---------------------------------------------------------------------------
ensure_template() {
  local template_name="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
  local template_path="${UBUNTU_TEMPLATE_STORAGE}:vztmpl/${template_name}"

  if pveam list "${UBUNTU_TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${template_name}"; then
    ok "Ubuntu 22.04 template already present."
  else
    msg "Downloading Ubuntu 22.04 LXC template..."
    pveam update
    pveam download "${UBUNTU_TEMPLATE_STORAGE}" "${template_name}" || \
      die "Failed to download Ubuntu 22.04 template."
    ok "Template downloaded."
  fi
  TEMPLATE_PATH="${template_path}"
}

# ---------------------------------------------------------------------------
# Build network string for pct create
# ---------------------------------------------------------------------------
build_net_string() {
  if [[ "${CT_NET}" == "static" ]]; then
    echo "name=eth0,bridge=vmbr0,ip=${CT_IP},gw=${CT_GW}"
  else
    echo "name=eth0,bridge=vmbr0,ip=dhcp"
  fi
}

# ---------------------------------------------------------------------------
# Create and start container
# ---------------------------------------------------------------------------
create_container() {
  local net_str
  net_str="$(build_net_string)"

  msg "Creating LXC container ${CT_ID}..."
  pct create "${CT_ID}" "${TEMPLATE_PATH}" \
    --hostname "${CT_HOSTNAME}" \
    --cores "${CT_CORES}" \
    --memory "${CT_MEMORY}" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "${net_str}" \
    --password "${CT_PASSWORD}" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype ubuntu \
    --start 0 \
    || die "pct create failed."
  ok "Container ${CT_ID} created."

  msg "Starting container..."
  pct start "${CT_ID}"
  wait_for_container
}

# ---------------------------------------------------------------------------
# Wait until container networking is up
# ---------------------------------------------------------------------------
wait_for_container() {
  msg "Waiting for container to become ready..."
  local attempts=0
  local max=30
  while (( attempts < max )); do
    if pct exec "${CT_ID}" -- true 2>/dev/null; then
      ok "Container is ready."
      return
    fi
    (( attempts++ ))
    sleep 2
  done
  die "Container did not become ready after $((max * 2)) seconds."
}

# ---------------------------------------------------------------------------
# Download build scripts into container and execute
# ---------------------------------------------------------------------------
run_install_in_container() {
  msg "Uploading install scripts to container..."

  # Create build dir inside container
  pct exec "${CT_ID}" -- mkdir -p /opt/paperclip-install/build

  # Push scripts into container via pct push
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ -f "${script_dir}/build/install.sh" ]]; then
    # Local dev path — scripts exist on this host
    pct push "${CT_ID}" "${script_dir}/build/install.sh"    /opt/paperclip-install/build/install.sh
    pct push "${CT_ID}" "${script_dir}/build/os-setup.sh"   /opt/paperclip-install/build/os-setup.sh
    pct push "${CT_ID}" "${script_dir}/build/nodejs.sh"     /opt/paperclip-install/build/nodejs.sh
    pct push "${CT_ID}" "${script_dir}/build/ollama.sh"     /opt/paperclip-install/build/ollama.sh
    pct push "${CT_ID}" "${script_dir}/build/paperclip.sh"  /opt/paperclip-install/build/paperclip.sh
    pct push "${CT_ID}" "${script_dir}/build/nginx.sh"      /opt/paperclip-install/build/nginx.sh
  else
    # Download from GitHub
    msg "Downloading build scripts from GitHub..."
    for script in install.sh os-setup.sh nodejs.sh ollama.sh paperclip.sh nginx.sh; do
      pct exec "${CT_ID}" -- bash -c \
        "wget -qO /opt/paperclip-install/build/${script} ${SCRIPT_BASE}/build/${script}"
    done
  fi

  # Make executable
  pct exec "${CT_ID}" -- chmod +x /opt/paperclip-install/build/*.sh

  msg "Running install.sh inside container..."
  pct exec "${CT_ID}" -- bash -c "
    export OLLAMA_MODEL='${OLLAMA_MODEL}'
    export ENABLE_NGINX='${ENABLE_NGINX}'
    bash /opt/paperclip-install/build/install.sh
  "
  ok "Install completed inside container."
}

# ---------------------------------------------------------------------------
# Print final summary
# ---------------------------------------------------------------------------
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "${CT_ID}" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1" 2>/dev/null || echo "unknown")

  echo
  echo "${BOLD}${GREEN}=== Paperclip Installation Complete! ===${RESET}"
  echo
  echo "  Container ID  : ${BOLD}${CT_ID}${RESET}"
  echo "  Hostname      : ${BOLD}${CT_HOSTNAME}${RESET}"
  echo "  IP Address    : ${BOLD}${ct_ip}${RESET}"
  if [[ "${ENABLE_NGINX}" =~ ^[Yy] ]]; then
    echo "  Paperclip URL : ${BOLD}https://${ct_ip}${RESET}"
  else
    echo "  Paperclip URL : ${BOLD}http://${ct_ip}:3100${RESET}"
  fi
  echo "  SSH access    : ${BOLD}ssh root@${ct_ip}${RESET}"
  echo
  echo "  Model pulled  : ${BOLD}${OLLAMA_MODEL}${RESET}"
  echo
  ok "Enjoy Paperclip on Proxmox!"
  echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  check_pve_version
  gather_config
  show_summary
  ensure_template
  create_container
  run_install_in_container
  print_summary
}

main "$@"
