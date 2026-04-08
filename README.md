# proxmox-paperclip

One-command installer for [Paperclip](https://paperclip.ing) on Proxmox VE — creates a dedicated Ubuntu 22.04 LXC container with Node.js, Ollama, and Paperclip pre-configured.

## Quick Install

Run the following command on your **Proxmox VE host** (not inside a container):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/proxmox-paperclip/proxmox-paperclip/main/ct/paperclip.sh)"
```

The installer will guide you through an interactive setup with sensible defaults.

## Requirements

| Requirement | Details |
|---|---|
| **Proxmox VE** | 8.0 or later |
| **Internet access** | Required on the PVE host and inside the container |
| **Storage** | At least 40 GB free on your CT storage |
| **RAM** | At least 8 GB available for the container |

## Resource Defaults

| Resource | Default | Override Env Var |
|---|---|---|
| Container ID | Auto-detected (next available) | `PAPERCLIP_CT_ID` |
| Hostname | `paperclip` | `PAPERCLIP_HOSTNAME` |
| CPU cores | 4 | `PAPERCLIP_CORES` |
| RAM | 8192 MB | `PAPERCLIP_MEMORY` |
| Disk | 40 GB | `PAPERCLIP_DISK` |
| Network | DHCP | `PAPERCLIP_NET` (`dhcp` or `static`) |
| Static IP | — | `PAPERCLIP_IP` (CIDR, e.g. `192.168.1.100/24`) |
| Gateway | — | `PAPERCLIP_GW` |
| Ollama model | `llama3.2` | `PAPERCLIP_MODEL` |
| HTTPS/nginx | No | `PAPERCLIP_NGINX` (`Y` or `N`) |
| Container storage | `local-lvm` | `PAPERCLIP_CT_STORAGE` |
| Template storage | `local` | `PAPERCLIP_TEMPLATE_STORAGE` |

## Non-Interactive (Automated) Mode

Set environment variables to skip all prompts:

```bash
export PAPERCLIP_CT_ID=200
export PAPERCLIP_HOSTNAME=paperclip
export PAPERCLIP_CORES=4
export PAPERCLIP_MEMORY=8192
export PAPERCLIP_DISK=40
export PAPERCLIP_NET=dhcp
export PAPERCLIP_MODEL=llama3.2
export PAPERCLIP_PASSWORD=your-secure-password
export PAPERCLIP_NGINX=N

bash -c "$(wget -qLO - https://raw.githubusercontent.com/proxmox-paperclip/proxmox-paperclip/main/ct/paperclip.sh)"
```

> **Security:** Never commit passwords to version control. Use environment variables or a secrets manager.

## What Gets Installed

Inside the LXC container:

| Component | Details |
|---|---|
| **Ubuntu 22.04 LTS** | Base OS (unprivileged container with nesting) |
| **Node.js 20 LTS** | Via NodeSource |
| **Ollama** | Latest, running as a systemd service |
| **Ollama model** | Your selected model (default: `llama3.2`) |
| **PM2** | Process manager for Paperclip |
| **paperclipai** | Latest release from npm |
| **nginx** _(optional)_ | Reverse proxy with self-signed TLS cert |

## Post-Install

After installation completes, the summary shows your container's IP and access URL.

### Access Paperclip

- **Without HTTPS:** `http://<container-ip>:3100`
- **With HTTPS:** `https://<container-ip>` (self-signed cert — accept browser warning)

### SSH into the container

```bash
ssh root@<container-ip>
```

Or from the PVE host:

```bash
pct enter <container-id>
```

### Manage Paperclip with PM2

```bash
# Inside the container
pm2 status
pm2 logs paperclip
pm2 restart paperclip
pm2 stop paperclip
```

### Manage Ollama models

```bash
# Inside the container
ollama list             # List installed models
ollama pull mistral     # Pull another model
ollama rm llama3.2      # Remove a model
```

## Script Structure

```
proxmox-paperclip/
├── ct/
│   └── paperclip.sh        # Main installer — run on PVE host
└── build/
    ├── install.sh           # Bootstrap orchestrator — run inside container
    ├── os-setup.sh          # System update + base packages
    ├── nodejs.sh            # Node.js 20 LTS install
    ├── ollama.sh            # Ollama install + model pull
    ├── paperclip.sh         # Paperclip + PM2 setup
    └── nginx.sh             # nginx SSL reverse proxy (optional)
```

## Troubleshooting

**Script fails at PVE version check:**
Ensure you are running this on a Proxmox VE 8.x host, not inside a container or VM.

**Template download fails:**
Check that your PVE host has internet access and that `local` storage has enough space.

**Paperclip not responding after install:**
```bash
pct exec <id> -- pm2 logs paperclip
pct exec <id> -- pm2 status
```

**Model pull timed out:**
Large models (7B+) can take 30+ minutes. Re-run `ollama pull <model>` inside the container after install.

**nginx certificate warning in browser:**
The installer uses a self-signed certificate. Add a browser exception or replace with a proper cert from Let's Encrypt.

## License

MIT
