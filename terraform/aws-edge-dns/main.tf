# Public DNS for the edge, managed separately from the edge stack so the
# Cloudflare provider cannot block instance operations. Apply only when a
# Cloudflare API token (Zone.DNS Edit) is available:
#
#   TF_VAR_cloudflare_api_token=... tofu apply
#
# The edge IP is read from the aws-edge stack's local state.

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

data "terraform_remote_state" "edge" {
  backend = "local"
  config = {
    path = "${path.module}/../aws-edge/terraform.tfstate"
  }
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
  default     = ["headscale", "auth", "dawarich"]
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
  content  = data.terraform_remote_state.edge.outputs.static_ip
  ttl      = 300
  proxied  = var.dns_proxied
}

output "records" {
  value = { for k, r in cloudflare_dns_record.public : k => r.content }
}
