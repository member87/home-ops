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

variable "admin_ssh_public_keys" {
  description = "Additional public keys installed for direct operator SSH access. Terraform's generated deployment key is included automatically."
  type        = list(string)
  default = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL3UXwi2ZmExP4hZLwcaRaryfSlUm9XTTwbMLv1pliEi",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKB5yZ34+4OSm/TIe0WEbvHRy8HR5QH22Im5K1UG4f84",
  ]
}
variable "edge_tailnet_ip" {
  description = "The edge's Headscale address. Terraform and operators SSH here; public 22/tcp is open only to Lightsail browser SSH. Rebuilding the instance registers a new tailnet node with a new address: read it from `headscale nodes list` and update this."
  type        = string
  default     = "100.64.0.21"
}

variable "frps_auth_token" {
  description = "frps auth token. REUSE the token from the old box so the in-cluster frpc keeps authenticating unchanged. Passing via TF_VAR_frps_auth_token keeps it out of git."
  type        = string
  sensitive   = true
}

variable "frps_dashboard_password" {
  description = "Password for the frps dashboard (127.0.0.1:7500, loopback-only)."
  type        = string
  sensitive   = true
}

variable "tailscale_authkey" {
  description = "Headscale preauth key the launch script uses to join the tailnet. Required: edge_config deploys over SSH to edge_tailnet_ip, so without the join only Lightsail browser SSH can reach the box. Also lets tailscale ping from this public vantage to k8s-subnet-router check for a direct path rather than DERP. Generate a FRESH key per instance recreation."
  type        = string
  sensitive   = true
  default     = ""
}


variable "manage_dns" {
  description = "Set true to let Terraform manage the public A records (requires cloudflare_api_token + cloudflare_zone_id). Sensitive values cannot drive for_each, hence this separate flag."
  type        = bool
  default     = false
}
variable "cloudflare_api_token" {
  description = "API token with Zone.DNS Edit on the zone. TF_VAR_cloudflare_api_token; never committed. Leave empty to manage DNS manually in the console."
  type        = string
  sensitive   = true
  default     = "disabled-dns-management"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id for the public domain (dashboard -> domain overview -> Zone ID). Only used when an API token is set."
  type        = string
  default     = ""
}

variable "public_domain" {
  description = "Public domain the edge serves."
  type        = string
  default     = "jackhumes.com"
}

variable "public_hostnames" {
  description = "Hostnames that must point at the edge static IP."
  type        = list(string)
  default     = ["headscale", "auth"]
}

variable "dns_proxied" {
  description = "Cloudflare proxy (orange cloud) for the public records. Keep false: ACME HTTP-01 and DERP need the real IP."
  type        = bool
  default     = false
}
