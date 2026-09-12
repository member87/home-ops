# Public DNS for the edge, managed separately from the edge stack so the
# Cloudflare provider cannot block instance operations. Runs execute in
# Terrakube (organization homeops, workspace aws-edge-dns) with
# cloudflare_api_token set as a sensitive workspace variable.
#
# The edge IP is read from the aws-edge workspace's state.

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

# The edge IP comes from the aws-edge workspace's state in Terrakube
# (https://terrakube.lab.jackhumes.com), not a local state file.
data "terraform_remote_state" "edge" {
  backend = "remote"
  config = {
    hostname     = "terrakube-api.lab.jackhumes.com"
    organization = "homeops"
    workspaces = {
      name = "aws-edge"
    }
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
