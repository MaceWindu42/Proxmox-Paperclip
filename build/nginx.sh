#!/usr/bin/env bash
# build/nginx.sh — Install nginx with self-signed SSL as a reverse proxy for Paperclip
set -euo pipefail

PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
CERT_DAYS="${CERT_DAYS:-365}"
CERT_DIR="/etc/nginx/ssl"
NGINX_CONF="/etc/nginx/sites-available/paperclip"

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

msg() { echo "${CYAN}${BOLD}[nginx]${RESET} $*"; }
ok()  { echo "${GREEN}✔${RESET} $*"; }
die() { echo "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  export DEBIAN_FRONTEND=noninteractive

  # Install nginx (idempotent)
  if dpkg -l nginx 2>/dev/null | grep -q "^ii"; then
    ok "nginx already installed."
  else
    msg "Installing nginx..."
    apt-get install -y -qq nginx
    ok "nginx installed."
  fi

  # Generate self-signed TLS certificate
  msg "Generating self-signed TLS certificate (${CERT_DAYS} days)..."
  mkdir -p "${CERT_DIR}"

  if [[ -f "${CERT_DIR}/paperclip.crt" && -f "${CERT_DIR}/paperclip.key" ]]; then
    ok "TLS certificate already exists, skipping generation."
  else
    openssl req -x509 -nodes \
      -days "${CERT_DAYS}" \
      -newkey rsa:2048 \
      -keyout "${CERT_DIR}/paperclip.key" \
      -out "${CERT_DIR}/paperclip.crt" \
      -subj "/C=US/ST=Local/L=Local/O=Paperclip/OU=Paperclip/CN=paperclip.local" \
      2>/dev/null
    chmod 600 "${CERT_DIR}/paperclip.key"
    ok "Self-signed certificate generated."
  fi

  # Write nginx config
  msg "Writing nginx reverse proxy config..."
  cat > "${NGINX_CONF}" <<EOF
# Paperclip reverse proxy — managed by proxmox-paperclip installer
server {
    listen 80;
    server_name _;
    # Redirect HTTP to HTTPS
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     ${CERT_DIR}/paperclip.crt;
    ssl_certificate_key ${CERT_DIR}/paperclip.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        proxy_pass         http://127.0.0.1:${PAPERCLIP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
EOF

  # Enable site
  ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/paperclip
  # Remove default site if present
  rm -f /etc/nginx/sites-enabled/default

  # Test config
  nginx -t || die "nginx configuration test failed."
  ok "nginx config is valid."

  # Enable and restart service
  systemctl enable nginx
  if systemctl is-active nginx &>/dev/null; then
    systemctl reload nginx
    ok "nginx reloaded."
  else
    systemctl start nginx
    ok "nginx started."
  fi
}

main "$@"
