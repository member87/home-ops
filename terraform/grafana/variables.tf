variable "grafana_url" {
  description = "Grafana base URL. Runs execute in the Terrakube executor pod, so this is the in-cluster Service DNS name rather than grafana.lab.jackhumes.com: no Traefik hop, no TLS trust, no dependency on ingress being healthy while dashboards are being applied."
  type        = string
  default     = "http://grafana.grafana.svc.cluster.local:3000"
}

variable "grafana_auth" {
  description = "Grafana service account token (glsa_...) for a service account with the Admin role. Set as a sensitive variable on the Terrakube workspace, never committed."
  type        = string
  sensitive   = true
}

variable "folders" {
  description = "Maps each directory under dashboards/ to the Grafana folder title it is provisioned into. A directory with no entry here fails the plan rather than silently landing dashboards in the General folder."
  type        = map(string)
  default = {
    kubernetes = "Kubernetes"
    logs       = "Logs"
    network    = "Network"
    security   = "Security"
    unifi      = "UniFi"
  }
}
