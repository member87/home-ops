#!/bin/bash
# Lightsail launch script: replicates the Oracle VPS ~/frp-tunnel stack
# (frps + Caddy, both host-network Docker) that fronts the home cluster.
set -euo pipefail

timedatectl set-timezone Europe/London

apt-get update
apt-get install -y ca-certificates curl
curl -fsSL https://get.docker.com | sh

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

volumes:
  caddy_data:
  caddy_config:
EOF

cat > /opt/frp-tunnel/frps.toml <<EOF
bindPort = 7000

auth.method = "token"
auth.token = "${frps_auth_token}"

# Dashboard, loopback-only (reach via: ssh -L 7500:127.0.0.1:7500 ubuntu@<static-ip>)
webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${frps_dashboard_password}"

transport.tls.force = false
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
EOF

cd /opt/frp-tunnel
systemctl enable --now docker
docker compose up -d
