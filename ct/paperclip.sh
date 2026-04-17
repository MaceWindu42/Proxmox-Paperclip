#!/usr/bin/env bash
# ct/paperclip.sh — Proxmox LXC installer for Paperclip
# Usage: bash -c "$(wget -qLO - https://raw.githubusercontent.com/MaceWindu42/Proxmox-Paperclip/main/ct/paperclip.sh)"
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors (terminal only)
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

trap 'die "Unexpected error at line ${LINENO} (exit code: $?). Check output above."' ERR

# ---------------------------------------------------------------------------
# Configuration — override with PXMX_* env vars for non-interactive mode
# ---------------------------------------------------------------------------
GITHUB_ORG="${GITHUB_ORG:-MaceWindu42}"
GITHUB_REPO="${GITHUB_REPO:-Proxmox-Paperclip}"
SCRIPT_BASE="https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/main"

CT_ID="${PXMX_CT_ID:-}"
CT_HOSTNAME="${PXMX_HOSTNAME:-paperclip}"
CT_CORES="${PXMX_CORES:-4}"
CT_MEMORY="${PXMX_MEMORY:-8192}"
CT_DISK="${PXMX_DISK:-40}"
CT_NET="${PXMX_NET:-dhcp}"
CT_IP="${PXMX_IP:-}"
CT_GW="${PXMX_GW:-}"
OLLAMA_MODEL="${PXMX_MODEL:-llama3.2}"
CT_PASSWORD="${PXMX_PASSWORD:-}"
ENABLE_NGINX="${PXMX_NGINX:-N}"
UBUNTU_TEMPLATE_STORAGE="${PXMX_TEMPLATE_STORAGE:-local}"
CT_STORAGE="${PXMX_CT_STORAGE:-local-lvm}"

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
header_info() {
  echo "${CYAN}${BOLD}"
  cat <<'EOF'
  ____                       _ _
 |  _ \ __ _ _ __   ___ _ __| (_)_ __
 | |_) / _` | '_ \ / _ \ '__| | | '_ \
 |  __/ (_| | |_) |  __/ |  | | | |_) |
 |_|   \__,_| .__/ \___|_|  |_|_| .__/
             |_|                 |_|
              Proxmox LXC Installer
EOF
  echo "${RESET}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root."
  fi
}

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
    (( id++ )) || true
  done
  echo "${id}"
}

# ---------------------------------------------------------------------------
# Ubuntu template discovery (dynamic — no hardcoded version)
# ---------------------------------------------------------------------------
find_ubuntu_template() {
  local storage="$1"
  local name
  for ver in "ubuntu-24.04" "ubuntu-22.04" "ubuntu-20.04"; do
    name=$(pveam list "${storage}" 2>/dev/null | awk '{print $1}' | grep "${ver}" | head -1 || true)
    if [[ -n "${name}" ]]; then
      echo "${name}"
      return
    fi
  done
  echo ""
}

download_ubuntu_template() {
  local storage="$1"
  local name
  pveam update || die "pveam update failed."
  for ver in "ubuntu-24.04" "ubuntu-22.04" "ubuntu-20.04"; do
    name=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep "${ver}" | head -1 || true)
    if [[ -n "${name}" ]]; then
      msg "Downloading ${name}..."
      pveam download "${storage}" "${name}" || die "Failed to download template ${name}."
      echo "${name}"
      return
    fi
  done
  die "No Ubuntu template found via pveam available. Check internet access and try again."
}

ensure_template() {
  local template_name
  template_name="$(find_ubuntu_template "${UBUNTU_TEMPLATE_STORAGE}")"
  if [[ -n "${template_name}" ]]; then
    ok "Ubuntu template found: ${template_name}"
    # find_ubuntu_template returns the full storage:vztmpl/name path from pveam list
    TEMPLATE_PATH="${template_name}"
  else
    msg "No Ubuntu template cached — downloading..."
    local dl_name
    dl_name="$(download_ubuntu_template "${UBUNTU_TEMPLATE_STORAGE}")"
    ok "Template downloaded: ${dl_name}"
    # download_ubuntu_template returns just the filename; prepend storage prefix
    TEMPLATE_PATH="${UBUNTU_TEMPLATE_STORAGE}:vztmpl/${dl_name}"
  fi
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
# Whiptail interactive configuration (community-scripts.org style TUI)
# ---------------------------------------------------------------------------
gather_config_whiptail() {
  local title="Paperclip LXC Installer"

  [[ -z "${CT_ID}" ]] && CT_ID="$(next_ct_id)"

  CT_ID=$(whiptail --title "${title}" \
    --inputbox "Container ID" 10 60 "${CT_ID}" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  CT_HOSTNAME=$(whiptail --title "${title}" \
    --inputbox "Hostname" 10 60 "${CT_HOSTNAME}" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  CT_CORES=$(whiptail --title "${title}" \
    --inputbox "CPU cores" 10 60 "${CT_CORES}" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  CT_MEMORY=$(whiptail --title "${title}" \
    --inputbox "RAM (MB)" 10 60 "${CT_MEMORY}" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  CT_DISK=$(whiptail --title "${title}" \
    --inputbox "Disk size (GB)" 10 60 "${CT_DISK}" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  # Network
  CT_NET=$(whiptail --title "${title}" \
    --default-item "${CT_NET}" \
    --menu "Network configuration" 13 60 2 \
    "dhcp"   "DHCP — automatic IP assignment" \
    "static" "Static IP — set address manually" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  if [[ "${CT_NET}" == "static" ]]; then
    CT_IP=$(whiptail --title "${title}" \
      --inputbox "Static IP (CIDR, e.g. 192.168.1.100/24)" 10 60 "${CT_IP}" \
      3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }
    CT_GW=$(whiptail --title "${title}" \
      --inputbox "Gateway (e.g. 192.168.1.1)" 10 60 "${CT_GW}" \
      3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }
  fi

  # Ollama model
  local model_choice
  model_choice=$(whiptail --title "${title}" \
    --default-item "${OLLAMA_MODEL}" \
    --menu "Select Ollama model to pull" 18 60 6 \
    "llama3.2" "Meta LLaMA 3.2 (recommended)" \
    "mistral"  "Mistral 7B" \
    "phi3"     "Microsoft Phi-3" \
    "gemma2"   "Google Gemma 2" \
    "custom"   "Enter custom model name" \
    "none"     "Skip model download" \
    3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }

  if [[ "${model_choice}" == "custom" ]]; then
    OLLAMA_MODEL=$(whiptail --title "${title}" \
      --inputbox "Enter Ollama model name" 10 60 "${OLLAMA_MODEL}" \
      3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }
  else
    OLLAMA_MODEL="${model_choice}"
  fi

  # Password (skip dialog if already set via PXMX_PASSWORD)
  if [[ -z "${CT_PASSWORD}" ]]; then
    local pass1 pass2
    while true; do
      pass1=$(whiptail --title "${title}" \
        --passwordbox "Container root password" 10 60 "" \
        3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }
      pass2=$(whiptail --title "${title}" \
        --passwordbox "Confirm password" 10 60 "" \
        3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }
      if [[ "${pass1}" == "${pass2}" && -n "${pass1}" ]]; then
        CT_PASSWORD="${pass1}"
        break
      fi
      whiptail --title "${title}" \
        --msgbox "Passwords do not match or are empty. Please try again." 8 60
    done
  fi

  # nginx HTTPS
  if whiptail --title "${title}" \
    --yesno "Enable HTTPS via nginx reverse proxy?" 10 60 --defaultno; then
    ENABLE_NGINX="Y"
  else
    ENABLE_NGINX="N"
  fi

  # Container storage pool (show menu only when more than one pool is available)
  local -a pool_menu=()
  local pool_count=0
  while read -r name _type status _rest; do
    if [[ "${status}" == "active" ]]; then
      pool_menu+=("${name}" "${name}")
      (( pool_count++ )) || true
    fi
  done < <(pvesm status --content rootdir 2>/dev/null | tail -n +2)

  if [[ "${pool_count}" -gt 1 ]]; then
    local list_h=$(( pool_count > 8 ? 8 : pool_count ))
    CT_STORAGE=$(whiptail --title "${title}" \
      --default-item "${CT_STORAGE}" \
      --menu "Select container storage pool" 15 60 "${list_h}" \
      "${pool_menu[@]}" \
      3>&1 1>&2 2>&3) || { msg "Aborted."; exit 0; }
  fi
}

# ---------------------------------------------------------------------------
# Text fallback interactive configuration (always prompts — never auto-skips)
# ---------------------------------------------------------------------------
gather_config_text() {
  echo
  echo "${BOLD}${CYAN}===  Paperclip LXC Installer  ===${RESET}"
  echo

  [[ -z "${CT_ID}" ]] && CT_ID="$(next_ct_id)"

  local input
  read -r -p "  Container ID [${BOLD}${CT_ID}${RESET}]: " input
  CT_ID="${input:-${CT_ID}}"

  read -r -p "  Hostname [${BOLD}${CT_HOSTNAME}${RESET}]: " input
  CT_HOSTNAME="${input:-${CT_HOSTNAME}}"

  read -r -p "  CPU cores [${BOLD}${CT_CORES}${RESET}]: " input
  CT_CORES="${input:-${CT_CORES}}"

  read -r -p "  RAM (MB) [${BOLD}${CT_MEMORY}${RESET}]: " input
  CT_MEMORY="${input:-${CT_MEMORY}}"

  read -r -p "  Disk size (GB) [${BOLD}${CT_DISK}${RESET}]: " input
  CT_DISK="${input:-${CT_DISK}}"

  # Network
  read -r -p "  Network [${BOLD}${CT_NET}${RESET}] (dhcp/static): " input
  CT_NET="${input:-${CT_NET}}"
  if [[ "${CT_NET}" == "static" ]]; then
    read -r -p "  Static IP (CIDR, e.g. 192.168.1.100/24) [${BOLD}${CT_IP:-}${RESET}]: " input
    CT_IP="${input:-${CT_IP}}"
    read -r -p "  Gateway (e.g. 192.168.1.1) [${BOLD}${CT_GW:-}${RESET}]: " input
    CT_GW="${input:-${CT_GW}}"
  fi

  # Ollama model
  echo
  echo "  Select Ollama model to pull:"
  echo "    1) llama3.2 (recommended)"
  echo "    2) mistral"
  echo "    3) phi3"
  echo "    4) gemma2"
  echo "    5) custom (enter manually)"
  echo "    6) none (skip model download)"
  local choice
  read -r -p "  Choice [current: ${BOLD}${OLLAMA_MODEL}${RESET}]: " choice
  case "${choice:-}" in
    1) OLLAMA_MODEL="llama3.2" ;;
    2) OLLAMA_MODEL="mistral" ;;
    3) OLLAMA_MODEL="phi3" ;;
    4) OLLAMA_MODEL="gemma2" ;;
    5)
      read -r -p "  Enter model name [${BOLD}${OLLAMA_MODEL}${RESET}]: " input
      OLLAMA_MODEL="${input:-${OLLAMA_MODEL}}"
      ;;
    6) OLLAMA_MODEL="none" ;;
    *) : ;; # Keep current value if blank or unrecognised
  esac

  # Password (always prompt; press enter to keep PXMX_PASSWORD if set)
  if [[ -n "${CT_PASSWORD}" ]]; then
    echo "  Admin password: ${BOLD}(PXMX_PASSWORD set — press enter to keep, or type new password)${RESET}"
  fi
  local pass1 pass2
  while true; do
    read -r -s -p "  Admin password: " pass1; echo
    if [[ -z "${pass1}" && -n "${CT_PASSWORD}" ]]; then
      break  # keep existing env-supplied password
    fi
    read -r -s -p "  Confirm password: " pass2; echo
    if [[ "${pass1}" == "${pass2}" && -n "${pass1}" ]]; then
      CT_PASSWORD="${pass1}"
      break
    fi
    warn "Passwords do not match or are empty. Try again."
  done

  # nginx
  read -r -p "  Enable HTTPS via nginx? [y/${BOLD}N${RESET}]: " input
  ENABLE_NGINX="${input:-${ENABLE_NGINX}}"
}

# ---------------------------------------------------------------------------
# Interactive configuration dispatcher
# ---------------------------------------------------------------------------
gather_config() {
  if command -v whiptail &>/dev/null; then
    gather_config_whiptail
  else
    gather_config_text
  fi
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
  echo "  Storage      : ${BOLD}${CT_STORAGE}${RESET}"
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
  pct start "${CT_ID}" || die "pct start failed."
  wait_for_container
}

# ---------------------------------------------------------------------------
# Wait until container is ready
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
    (( attempts++ )) || true
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
  pct exec "${CT_ID}" -- mkdir -p /opt/paperclip-install/build \
    || die "Failed to create install directory in container."

  # Push scripts into container via pct push
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ -f "${script_dir}/build/install.sh" ]]; then
    # Local dev path — scripts exist on this host
    pct push "${CT_ID}" "${script_dir}/build/install.sh"    /opt/paperclip-install/build/install.sh   || die "Failed to push install.sh."
    pct push "${CT_ID}" "${script_dir}/build/os-setup.sh"   /opt/paperclip-install/build/os-setup.sh  || die "Failed to push os-setup.sh."
    pct push "${CT_ID}" "${script_dir}/build/nodejs.sh"     /opt/paperclip-install/build/nodejs.sh    || die "Failed to push nodejs.sh."
    pct push "${CT_ID}" "${script_dir}/build/ollama.sh"     /opt/paperclip-install/build/ollama.sh    || die "Failed to push ollama.sh."
    pct push "${CT_ID}" "${script_dir}/build/paperclip.sh"  /opt/paperclip-install/build/paperclip.sh || die "Failed to push paperclip.sh."
    pct push "${CT_ID}" "${script_dir}/build/nginx.sh"      /opt/paperclip-install/build/nginx.sh     || die "Failed to push nginx.sh."
  else
    # Download from GitHub
    msg "Downloading build scripts from GitHub..."
    for script in install.sh os-setup.sh nodejs.sh ollama.sh paperclip.sh nginx.sh; do
      pct exec "${CT_ID}" -- bash -c \
        "wget -qO /opt/paperclip-install/build/${script} ${SCRIPT_BASE}/build/${script}" \
        || die "Failed to download ${script} from GitHub."
    done
  fi

  # Make executable
  pct exec "${CT_ID}" -- chmod +x /opt/paperclip-install/build/*.sh \
    || die "Failed to make install scripts executable."

  msg "Running install.sh inside container..."
  # Pass env vars via 'env' to avoid shell injection from user-supplied values
  # (e.g. a custom model name containing single quotes or shell metacharacters)
  pct exec "${CT_ID}" -- \
    env "OLLAMA_MODEL=${OLLAMA_MODEL}" "ENABLE_NGINX=${ENABLE_NGINX}" \
    bash /opt/paperclip-install/build/install.sh \
    || die "Install script failed inside container."
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
  check_root
  check_pve_version
  header_info
  gather_config
  show_summary
  ensure_template
  create_container
  run_install_in_container
  print_summary
}

main "$@"
