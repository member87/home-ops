# Instance replacement intentionally cascades to the static-IP attachment,
# firewall, bootstrap wait, and service deployment resources below.

# var.region was previously unused: local runs inherited the region from
# ~/.aws/config, so the Terrakube executor had no region at all and every plan
# failed with "invalid AWS Region".
locals {
  edge_docker_compose     = file("${path.module}/config/docker-compose.yml")
  edge_caddy_config       = file("${path.module}/config/Caddyfile")
  edge_prometheus_agent   = file("${path.module}/config/prometheus-agent.yml")
  edge_egress_cap_service = file("${path.module}/config/egress-cap.service")
  edge_frps_config = templatefile("${path.module}/config/frps.toml.tftpl", {
    frps_auth_token         = var.frps_auth_token
    frps_dashboard_password = var.frps_dashboard_password
  })
  edge_authorized_keys = "${join("\n", [
    for key in concat([tls_private_key.edge.public_key_openssh], var.admin_ssh_public_keys) :
    regex("^\\S+\\s+\\S+", trimspace(key))
  ])}\n"

  edge_config_hashes = {
    docker_compose   = sha256(local.edge_docker_compose)
    caddy            = sha256(local.edge_caddy_config)
    prometheus_agent = sha256(local.edge_prometheus_agent)
    egress_cap       = sha256(local.edge_egress_cap_service)
    frps             = sha256(local.edge_frps_config)
    authorized_keys  = sha256(local.edge_authorized_keys)
  }
}

provider "aws" {
  region = var.region
}

# Terraform owns both client and host identities. Private material exists only
# as sensitive Terrakube state and is never committed or exposed as output.
# Anyone who can read that state can authenticate to the edge.
resource "tls_private_key" "edge" {
  algorithm = "ED25519"
}

resource "tls_private_key" "edge_host" {
  algorithm = "ED25519"
}

resource "aws_lightsail_key_pair" "edge" {
  name       = "${var.instance_name}-key"
  public_key = tls_private_key.edge.public_key_openssh
}

resource "aws_lightsail_instance" "edge" {
  name              = var.instance_name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.edge.name
  ip_address_type   = "dualstack"

  # Bootstrap uses the same rendered files that terraform_data.edge_config
  # continuously deploys to an existing instance. user_data stays ignored
  # because changing it would replace the Lightsail instance.
  user_data = templatefile("${path.module}/launch.sh.tpl", {
    docker_compose_b64          = base64encode(local.edge_docker_compose)
    caddy_config_b64            = base64encode(local.edge_caddy_config)
    prometheus_agent_config_b64 = base64encode(local.edge_prometheus_agent)
    egress_cap_service_b64      = base64encode(local.edge_egress_cap_service)
    frps_config_b64             = base64encode(local.edge_frps_config)
    authorized_keys_b64         = base64encode(local.edge_authorized_keys)
    ssh_host_private_key_b64    = base64encode(tls_private_key.edge_host.private_key_openssh)
    ssh_host_public_key_b64     = base64encode(tls_private_key.edge_host.public_key_openssh)
    tailscale_authkey           = var.tailscale_authkey
  })

  # user_data is ForceNew and only runs on first boot. Live service changes are
  # converged separately by terraform_data.edge_config without replacing the VM.
  lifecycle {
    ignore_changes       = [user_data]
    replace_triggered_by = [aws_lightsail_key_pair.edge, tls_private_key.edge_host]
  }

  tags = {
    Purpose = "home-ops public edge: frps + Caddy"
  }
}

# First static IP attached to an instance is free.
resource "aws_lightsail_static_ip" "edge" {
  name = "${var.instance_name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "edge" {
  static_ip_name = aws_lightsail_static_ip.edge.name
  instance_name  = aws_lightsail_instance.edge.name

  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.edge]
  }
}


# Platform firewall replaces the Oracle box's host iptables entirely
# (Lightsail Ubuntu images ship with no restrictive host rules).
# This resource owns the COMPLETE port set - any port not listed is closed.
resource "aws_lightsail_instance_public_ports" "edge" {
  instance_name = aws_lightsail_instance.edge.name

  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.edge]
  }

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = var.admin_cidrs
  }

  port_info {
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  # Caddy TLS: auth/headscale/dawarich public entrypoints.
  port_info {
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  # frps control/data channel for the in-cluster frpc. Token-authenticated,
  # same exposure as the Oracle box. Tighten to the home IP if you accept
  # re-applying whenever the broadband IP changes.
  port_info {
    protocol   = "tcp"
    from_port  = 7000
    to_port    = 7000
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }

  # STUN for the headscale embedded DERP region. MUST stay public - this is
  # what lets tailnet peers discover public endpoints and form direct
  # WireGuard paths instead of relaying through this box.
  port_info {
    protocol   = "udp"
    from_port  = 3478
    to_port    = 3478
    cidrs      = ["0.0.0.0/0"]
    ipv6_cidrs = ["::/0"]
  }
}

# Lightsail reports the instance ready before its launch script replaces the
# generated SSH host key. Wait once per instance so the pinned connection below
# never races the bootstrap identity.
resource "terraform_data" "edge_bootstrap_wait" {
  provisioner "local-exec" {
    command = "sleep 30"
  }

  depends_on = [
    aws_lightsail_instance_public_ports.edge,
    aws_lightsail_static_ip_attachment.edge,
  ]

  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.edge]
  }
}

# Configuration changes replace only this resource. Its create provisioners
# validate and deploy the files in-place, then recreate the Compose services.
resource "terraform_data" "edge_config" {
  triggers_replace = local.edge_config_hashes

  connection {
    type        = "ssh"
    host        = aws_lightsail_static_ip.edge.ip_address
    user        = "ubuntu"
    private_key = tls_private_key.edge.private_key_openssh
    host_key    = tls_private_key.edge_host.public_key_openssh
    timeout     = "2m"
  }

  provisioner "file" {
    content     = local.edge_docker_compose
    destination = "/tmp/edge-docker-compose.yml"
  }

  provisioner "file" {
    content     = local.edge_frps_config
    destination = "/tmp/edge-frps.toml"
  }

  provisioner "file" {
    content     = local.edge_caddy_config
    destination = "/tmp/edge-Caddyfile"
  }

  provisioner "file" {
    content     = local.edge_prometheus_agent
    destination = "/tmp/edge-prometheus-agent.yml"
  }

  provisioner "file" {
    content     = local.edge_egress_cap_service
    destination = "/tmp/edge-egress-cap.service"
  }

  provisioner "file" {
    content     = local.edge_authorized_keys
    destination = "/tmp/edge-authorized_keys"
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "timeout 300 sh -c 'until command -v docker >/dev/null 2>&1; do sleep 5; done'",
      "chmod 600 /tmp/edge-frps.toml",
      "sudo systemctl enable --now docker",
      "VPCIP=$(ip -4 -o addr show scope global | awk '$2!=\"tailscale0\" {sub(\"/.*\", \"\", $4); print $4; exit}'); test -n \"$VPCIP\"",
      "sed \"s/__VPCIP__/$VPCIP/\" /tmp/edge-docker-compose.yml > /tmp/edge-docker-compose.rendered.yml",
      "sudo docker compose -f /tmp/edge-docker-compose.rendered.yml config --quiet",
      "sudo docker run --rm -v /tmp/edge-frps.toml:/etc/frp/frps.toml:ro fatedier/frps:v0.61.1 verify -c /etc/frp/frps.toml",
      "sudo docker run --rm --entrypoint promtool -v /tmp/edge-prometheus-agent.yml:/etc/prometheus/prometheus.yml:ro prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml",
      "sudo docker run --rm -v /tmp/edge-Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile",
      "sudo install -d -m 0755 /opt/frp-tunnel /var/log/caddy",
      "sudo install -d -o ubuntu -g ubuntu -m 0700 /home/ubuntu/.ssh",
      "sudo install -o ubuntu -g ubuntu -m 0600 /tmp/edge-authorized_keys /home/ubuntu/.ssh/authorized_keys",
      "sudo install -m 0644 /tmp/edge-docker-compose.rendered.yml /opt/frp-tunnel/docker-compose.yml",
      "sudo install -m 0600 /tmp/edge-frps.toml /opt/frp-tunnel/frps.toml",
      "sudo install -m 0644 /tmp/edge-Caddyfile /opt/frp-tunnel/Caddyfile",
      "sudo install -m 0644 /tmp/edge-prometheus-agent.yml /opt/frp-tunnel/prometheus-agent.yml",
      "sudo install -m 0644 /tmp/edge-egress-cap.service /etc/systemd/system/egress-cap.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable egress-cap.service",
      "sudo systemctl restart egress-cap.service",
      "sudo docker compose -f /opt/frp-tunnel/docker-compose.yml up -d --force-recreate --remove-orphans --wait --wait-timeout 90",
      "curl -fsS http://127.0.0.1:9100/metrics >/dev/null",
      "curl -fsS http://127.0.0.1:9090/-/ready >/dev/null",
      "timeout 60 sh -c 'until ss -lntH | grep -q \"127.0.0.1:9091\"; do sleep 2; done'",
      "ss -lntH | awk '$4 ~ /:9091$/ && $4 != \"127.0.0.1:9091\" {exit 1}'",
      "rm -f /tmp/edge-docker-compose.yml /tmp/edge-docker-compose.rendered.yml /tmp/edge-frps.toml /tmp/edge-Caddyfile /tmp/edge-prometheus-agent.yml /tmp/edge-egress-cap.service /tmp/edge-authorized_keys",
    ]
  }

  depends_on = [terraform_data.edge_bootstrap_wait]

  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.edge]
  }
}

output "static_ip" {
  description = "Public IPv4 for DNS + frpc serverAddr + headscale derp.ipv4 cutover."
  value       = aws_lightsail_static_ip.edge.ip_address
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_lightsail_static_ip.edge.ip_address}"
}
