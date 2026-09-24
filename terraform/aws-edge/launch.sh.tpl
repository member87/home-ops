#!/bin/bash
# Lightsail executes launch scripts with sh/dash; re-exec under bash.
if [ -z "$${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

# Use the Terraform-owned host identity before configuration management connects.
# HostKeyAlgorithms prevents sshd from selecting an image-generated fallback key.
printf '%s' '${ssh_host_private_key_b64}' | base64 --decode > /etc/ssh/ssh_host_ed25519_key
printf '%s' '${ssh_host_public_key_b64}' | base64 --decode > /etc/ssh/ssh_host_ed25519_key.pub
chmod 600 /etc/ssh/ssh_host_ed25519_key
chmod 644 /etc/ssh/ssh_host_ed25519_key.pub
install -d -o ubuntu -g ubuntu -m 0700 /home/ubuntu/.ssh
printf '%s' '${authorized_keys_b64}' | base64 --decode > /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-home-ops-host-key.conf <<'EOF'
HostKey /etc/ssh/ssh_host_ed25519_key
HostKeyAlgorithms ssh-ed25519
EOF
# cloud-init validates user scripts before Ubuntu's ssh service creates this.
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
systemctl restart ssh

timedatectl set-timezone Europe/London

# Docker's large packages OOM-kill dpkg on the 512 MB bundle without swap.
# Keep this idempotent so a failed bootstrap can be resumed safely.
if ! swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

apt-get update
apt-get install -y ca-certificates curl
# The Lightsail image may activate Snap Docker during initialization. Its
# confinement cannot bind-mount the managed files under /opt.
if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  snap remove docker
fi
curl -fsSL https://get.docker.com | sh

mkdir -p /opt/frp-tunnel /var/log/caddy

# These files are rendered from terraform/aws-edge/config. Terraform also deploys
# the same content to existing instances through terraform_data.edge_config.
printf '%s' '${docker_compose_b64}' | base64 --decode > /opt/frp-tunnel/docker-compose.yml
printf '%s' '${frps_config_b64}' | base64 --decode > /opt/frp-tunnel/frps.toml
printf '%s' '${prometheus_agent_config_b64}' | base64 --decode > /opt/frp-tunnel/prometheus-agent.yml
printf '%s' '${caddy_config_b64}' | base64 --decode > /opt/frp-tunnel/Caddyfile
printf '%s' '${egress_cap_service_b64}' | base64 --decode > /etc/systemd/system/egress-cap.service
chmod 600 /opt/frp-tunnel/frps.toml

# Bind coturn ONLY to the VPC private IP. Binding all interfaces (or the
# tailscale0 address) coincided with two full network blackholes on this
# box; the derpmap advertises the public IP, and 1:1 NAT delivers packets
# to the VPC address, so the tailscale interface is never needed here.
VPCIP=$(ip -4 -o addr show scope global | awk '$2!="tailscale0" {split($4,a,"/"); print a[1]}' | head -1)
sed -i "s/__VPCIP__/$VPCIP/" /opt/frp-tunnel/docker-compose.yml

cd /opt/frp-tunnel
systemctl enable --now docker

# Egress cap FIRST: a 4mbit tbf bounds relay burn from any broken client.
# Applied before the tailnet join so a hanging join can never leave the
# box without its guardrails.
systemctl daemon-reload
systemctl enable --now egress-cap.service

docker compose up -d

# Join the tailnet LAST, bounded, and non-fatal: enrollment depends on Headscale
# becoming reachable through the Caddy/FRP services started immediately above.
if [ -n "${tailscale_authkey}" ]; then
  curl -fsSL https://tailscale.com/install.sh | sh
  timeout 60 tailscale up \
    --login-server=https://headscale.jackhumes.com \
    --authkey="${tailscale_authkey}" \
    --hostname=aws-edge \
    --accept-dns=false \
    || echo "tailscale join failed (non-fatal)"
fi
