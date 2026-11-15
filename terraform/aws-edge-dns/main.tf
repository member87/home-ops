# Public DNS for the edge: an A record per public hostname, pointing at the NixOS edge
# (nixos/edge). There is no Terrakube workspace for this stack; apply it from the
# workstation with TF_VAR_cloudflare_api_token and TF_VAR_cloudflare_zone_id set, and
#   TF_VAR_edge_ipv4=$(sops -d --extract '["public_ipv4"]' nixos/edge/secrets.yaml)
# so the IP never appears in this public repo. Jevil's edge lint reads public_hostnames here.

terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

variable "edge_ipv4" {
  description = "Public IPv4 of the edge (nixos/edge), public_ipv4 in nixos/edge/secrets.yaml. Only A records: coturn answers STUN on IPv4 only, so an AAAA record would break STUN lookups by name."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "API token with Zone.DNS Edit on the zone. TF_VAR_cloudflare_api_token; never committed."
  type        = string
  sensitive   = true
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
  default     = ["headscale", "auth", "terrakube-hook", "gotify"]
}

variable "dns_proxied" {
  description = "Cloudflare proxy (orange cloud) for the public records. Keep false: ACME HTTP-01 and DERP need the real IP."
  type        = bool
  default     = false
}

resource "cloudflare_dns_record" "public" {
  for_each = toset(var.public_hostnames)
  zone_id  = var.cloudflare_zone_id
  name     = "${each.key}.${var.public_domain}"
  type     = "A"
  content  = var.edge_ipv4
  ttl      = 300
  proxied  = var.dns_proxied
}

output "records" {
  value = { for k, r in cloudflare_dns_record.public : k => r.content }
}
