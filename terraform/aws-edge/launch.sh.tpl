#!/bin/bash
# Lightsail executes launch scripts with sh/dash; re-exec under bash.
if [ -z "$${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

timedatectl set-timezone Europe/London

apt-get update
apt-get install -y ca-certificates curl
curl -fsSL https://get.docker.com | sh

# 512MB RAM is tight for docker+4 daemons; spikes (cert ops, pulls, netcheck
# bursts) otherwise trigger reclaim storms that blackhole networking.
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

mkdir -p /opt/frp-tunnel /var/log/caddy

cat > /opt/frp-tunnel/docker-compose.yml <<'EOF'
services:
  frps:
    image: fatedier/frps:v0.61.1
    container_name: frps
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./frps.toml:/etc/frp/frps.toml:ro
    command: -c /etc/frp/frps.toml

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

  coturn:
    image: coturn/coturn:4.6.3
    container_name: coturn
    restart: unless-stopped
    network_mode: host
    command: -n --stun-only --no-cli --no-tls --no-dtls --listening-ip=__VPCIP__ --listening-port=3478

  node-exporter:
    image: prom/node-exporter:v1.12.1
    container_name: node-exporter
    restart: unless-stopped
    network_mode: host
    command:
      - --web.listen-address=127.0.0.1:9100
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --path.rootfs=/host/root
      - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+)($|/)
      - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro,rslave

  prometheus-agent:
    image: prom/prometheus:v3.14.0
    container_name: prometheus-agent
    restart: unless-stopped
    network_mode: host
    command:
      - --web.listen-address=127.0.0.1:9090
      - --config.file=/etc/prometheus/prometheus.yml
      - --agent
      - --storage.agent.path=/prometheus
    volumes:
      - ./prometheus-agent.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_agent_data:/prometheus

volumes:
  caddy_data:
  caddy_config:
  prometheus_agent_data:
EOF

cat > /opt/frp-tunnel/frps.toml <<EOF
bindPort = 7000

# Caddy is the public entrypoint. All FRP proxy ports, including the metrics
# receiver, are loopback-only; frpc control traffic still uses bindPort 7000.
proxyBindAddr = "127.0.0.1"

auth.method = "token"
auth.token = "${frps_auth_token}"

# Dashboard, loopback-only (reach via: ssh -L 7500:127.0.0.1:7500 ubuntu@<static-ip>)
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${frps_dashboard_password}"

transport.tls.force = false
EOF

# The agent is deliberately host-networked: remote-write reaches FRP on
# loopback and node-exporter is never exposed on the public interface.
cat > /opt/frp-tunnel/prometheus-agent.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: aws-edge-node
    static_configs:
      - targets: ["127.0.0.1:9100"]
        labels:
          instance: aws-edge

  - job_name: aws-edge-prometheus-agent
    static_configs:
      - targets: ["127.0.0.1:9090"]
        labels:
          instance: aws-edge

remote_write:
  - url: http://127.0.0.1:9091/api/v1/write
EOF

# Caddy auto-issues Let's Encrypt certs once public DNS points here.
cat > /opt/frp-tunnel/Caddyfile <<'EOF'
# Pocket ID (auth via Traefik) - public access
auth.jackhumes.com {
	reverse_proxy localhost:8081
	log {
		output file /var/log/caddy/auth.log
	}
}

# Headscale control plane + embedded DERP - public access
headscale.jackhumes.com {
	reverse_proxy localhost:8082
	log {
		output file /var/log/caddy/headscale.log
	}
}

# Dawarich (via Traefik) - public access
dawarich.jackhumes.com {
	reverse_proxy localhost:8083
	log {
		output file /var/log/caddy/dawarich.log
	}
}

# Terrakube GitHub webhook receiver (via Traefik -> in-cluster gatekeeper).
# Only the webhook path is public; the Terrakube UI and API stay on the LAN.
terrakube-hook.jackhumes.com {
	reverse_proxy localhost:8084
	log {
		output file /var/log/caddy/terrakube-hook.log
	}
}
EOF

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
cat > /etc/systemd/system/egress-cap.service <<'EOF'
[Unit]
Description=Egress bandwidth cap (Lightsail data-transfer budget guard)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/tc qdisc replace dev ens5 root tbf rate 4mbit burst 256kbit latency 50ms
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now egress-cap.service

docker compose up -d

# Join the tailnet LAST and non-fatal: the box must serve public traffic
# even if the join fails; the edge re-provisions cleanly on the next apply.
if [ -n "${tailscale_authkey}" ]; then
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up \
    --login-server=https://headscale.jackhumes.com \
    --authkey="${tailscale_authkey}" \
    --hostname=aws-edge \
    --accept-dns=false \
    || echo "tailscale join failed (non-fatal)"
fi
