#!/usr/bin/env bash
# One-time host hardening for the plutonium homelab host.
# Run once as a user with sudo access after a fresh Ubuntu install.
# Safe to re-run — all steps are idempotent.
#
# Usage: bash harden.sh [--lan-subnet 192.168.x.0/24] [--lan-ip 192.168.x.x]

set -euo pipefail

# ============================================================
# Args / defaults
# ============================================================

LAN_SUBNET=""
LAN_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-subnet) LAN_SUBNET="$2"; shift 2 ;;
    --lan-ip)     LAN_IP="$2";     shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$LAN_SUBNET" || -z "$LAN_IP" ]]; then
  echo "Usage: bash harden.sh --lan-subnet 192.168.x.0/24 --lan-ip 192.168.x.x" >&2
  exit 1
fi

echo "==> LAN subnet: $LAN_SUBNET"
echo "==> LAN IP:     $LAN_IP"
echo ""

# ============================================================
# System updates
# ============================================================

echo "==> Updating system packages"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq ufw fail2ban curl

# ============================================================
# SSH hardening
# ============================================================

echo "==> Hardening SSH"
SSHD=/etc/ssh/sshd_config

sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD"
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD"
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD"

# Verify at least one authorized key exists before restarting sshd
if [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
  echo ""
  echo "WARNING: ~/.ssh/authorized_keys is empty or missing." >&2
  echo "         Add your public key before restarting SSH or you will be locked out." >&2
  echo "         Skipping sshd restart." >&2
  echo ""
else
  sudo systemctl restart sshd
  echo "    sshd restarted — confirm key-based login works in a new session before closing this one"
fi

# ============================================================
# fail2ban
# ============================================================

echo "==> Enabling fail2ban"
sudo systemctl enable --now fail2ban

# ============================================================
# Docker daemon config
# ============================================================

echo "==> Writing /etc/docker/daemon.json"
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true
}
EOF

# ============================================================
# Docker install
# ============================================================

if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "    NOTE: log out and back in (or run 'newgrp docker') for group membership to take effect"
else
  echo "==> Docker already installed ($(docker --version))"
fi

sudo systemctl restart docker

# ============================================================
# UFW
# ============================================================

echo "==> Configuring UFW"
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH — open to all (Tailscale + LAN)
sudo ufw allow ssh

# Monitoring — LAN only
sudo ufw allow from "$LAN_SUBNET" to any port 3000 comment "Grafana"
sudo ufw allow from "$LAN_SUBNET" to any port 3100 comment "Loki"
sudo ufw allow from "$LAN_SUBNET" to any port 9090 comment "Prometheus"

# Application services — LAN only
sudo ufw allow from "$LAN_SUBNET" to any port 5678 comment "n8n"
sudo ufw allow from "$LAN_SUBNET" to any port 8000 comment "Paperless"
sudo ufw allow from "$LAN_SUBNET" to any port 8001 comment "iSponsorBlockTV"

sudo ufw --force enable
sudo ufw status verbose

# ============================================================
# Tailscale (host-level)
# ============================================================

if ! command -v tailscale &>/dev/null; then
  echo "==> Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
  echo ""
  echo "    Run the following to connect this host to your tailnet:"
  echo "    sudo tailscale up --advertise-tags=tag:homelab-host"
  echo ""
else
  echo "==> Tailscale already installed ($(tailscale version | head -1))"
fi

# ============================================================
# Shared Docker network
# ============================================================

if ! docker network inspect plutonium &>/dev/null 2>&1; then
  echo "==> Creating shared Docker network: plutonium"
  docker network create plutonium
else
  echo "==> Docker network 'plutonium' already exists"
fi

# ============================================================
# Done
# ============================================================

echo ""
echo "==> Host hardening complete."
echo ""
echo "Next steps:"
echo "  1. Confirm SSH key-based login works in a new terminal"
echo "  2. Run: sudo tailscale up --advertise-tags=tag:homelab-host"
echo "  3. Clone the repo and fill in .env files"
echo "  4. Run: docker compose up -d in each service directory"
