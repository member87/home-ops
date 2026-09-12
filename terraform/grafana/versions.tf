terraform {
  required_version = ">= 1.6"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.9"
    }
  }
  # State lives in the Terrakube workspace "grafana" (organization homeops);
  # runs execute remotely. Never commit *.tfstate (gitignored).
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}
