variable "region" {
  description = "AWS region. eu-west-2 (London) matches the old Oracle uk-london-1 edge, keeping DERP latency ~5-10ms for UK clients."
  type        = string
  default     = "eu-west-2"
}

variable "availability_zone" {
  description = "AZ for the Lightsail instance (must be in var.region)."
  type        = string
  default     = "eu-west-2a"
}

variable "instance_name" {
  description = "Lightsail instance name."
  type        = string
  default     = "home-ops-edge"
}

variable "blueprint_id" {
  description = "Lightsail OS blueprint. Run `aws lightsail get-blueprints --region eu-west-2` to list current ids."
  type        = string
  default     = "ubuntu_24_04"
}

variable "bundle_id" {
  description = "Lightsail bundle. nano_3_0 = 512MB/2vCPU (~$5/mo incl. public IPv4) - Caddy+frps use ~50MB total on the old box. Bump to micro_3_0 (1GB) for headroom."
  type        = string
  default     = "nano_3_0"
}

variable "ssh_public_key_path" {
  description = "Local path to the SSH public key to install for the 'ubuntu' user (same key as the old Oracle VPS)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH (22/tcp). Lightsail browser SSH remains available as a fallback if your home IP changes."
  type        = list(string)
  default     = ["143.58.248.115/32"] # home broadband (2026-09)
}

variable "frps_auth_token" {
  description = "frps auth token. REUSE the token from the Oracle box so the in-cluster frpc keeps authenticating unchanged: ssh ubuntu@140.238.67.83 'grep -A1 auth.token ~/frp-tunnel/frps.toml'. Passing via TF_VAR_frps_auth_token keeps it out of git."
  type        = string
  sensitive   = true
}

variable "frps_dashboard_password" {
  description = "Password for the frps dashboard (127.0.0.1:7500, loopback-only)."
  type        = string
  sensitive   = true
}

variable "tailscale_authkey" {
  description = "Headscale preauth key so the edge joins the tailnet as a remote probe node (headscale preauthkeys create --user 1 --reusable --expiration 720h). Enables E2E direct-path verification: tailscale ping from this public vantage to k8s-subnet-router must go direct, not via DERP. Empty string skips the join."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_api_token" {
  description = "API token with Zone.DNS Edit on the zone. TF_VAR_cloudflare_api_token; never committed."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id for the public domain (dashboard -> domain overview -> Zone ID)."
  type        = string
}

variable "public_domain" {
  description = "Public domain the edge serves."
  type        = string
  default     = "jackhumes.com"
}

variable "public_hostnames" {
  description = "Hostnames that must point at the edge static IP."
  type        = list(string)
  default     = ["headscale", "auth", "dawarich"]
}

variable "dns_proxied" {
  description = "Cloudflare proxy (orange cloud) for the public records. Keep false: ACME HTTP-01 and DERP need the real IP."
  type        = bool
  default     = false
}
