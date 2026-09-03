provider "aws" {
  region = var.region
}

# Registers the workstation's existing key with Lightsail so `ssh ubuntu@<ip>`
# works exactly like it did against the Oracle VPS.
resource "aws_lightsail_key_pair" "edge" {
  name       = "${var.instance_name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_lightsail_instance" "edge" {
  name              = var.instance_name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.edge.name
  ip_address_type   = "dualstack"

  # Shell script (Lightsail launch script, not cloud-init YAML).
  # NOTE: user_data is readable by anyone with lightsail:GetInstance access;
  # the frps token is also known to the cluster-side frpc secret anyway.
  user_data = templatefile("${path.module}/launch.sh.tpl", {
    frps_auth_token         = var.frps_auth_token
    frps_dashboard_password = var.frps_dashboard_password
    tailscale_authkey       = var.tailscale_authkey
  })

  tags = {
    Purpose = "home-ops public edge (frps + Caddy)"
  }
}

# First static IP attached to an instance is free.
resource "aws_lightsail_static_ip" "edge" {
  name = "${var.instance_name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "edge" {
  static_ip_name = aws_lightsail_static_ip.edge.name
  instance_name  = aws_lightsail_instance.edge.name
}

# Platform firewall replaces the Oracle box's host iptables entirely
# (Lightsail Ubuntu images ship with no restrictive host rules).
# This resource owns the COMPLETE port set - any port not listed is closed.
resource "aws_lightsail_instance_public_ports" "edge" {
  instance_name = aws_lightsail_instance.edge.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = var.admin_cidrs
  }

  # Caddy HTTP->HTTPS redirects + ACME HTTP-01 fallback.
  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidrs     = ["0.0.0.0/0", "::/0"]
  }

  # Caddy TLS: auth/headscale/dawarich public entrypoints.
  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
    cidrs     = ["0.0.0.0/0", "::/0"]
  }

  # frps control/data channel for the in-cluster frpc. Token-authenticated,
  # same exposure as the Oracle box. Tighten to the home IP if you accept
  # re-applying whenever the broadband IP changes.
  port_info {
    protocol  = "tcp"
    from_port = 7000
    to_port   = 7000
    cidrs     = ["0.0.0.0/0", "::/0"]
  }

  # STUN for the headscale embedded DERP region. MUST stay public - this is
  # what lets tailnet peers discover public endpoints and form direct
  # WireGuard paths instead of relaying through this box.
  port_info {
    protocol  = "udp"
    from_port = 3478
    to_port   = 3478
    cidrs     = ["0.0.0.0/0", "::/0"]
  }
}

output "static_ip" {
  description = "Public IPv4 for DNS + frpc serverAddr + headscale derp.ipv4 cutover."
  value       = aws_lightsail_static_ip.edge.ip_address
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_lightsail_static_ip.edge.ip_address}"
}
