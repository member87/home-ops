output "dashboard_count" {
  description = "Number of dashboards managed here. Compare against the file count to catch a dashboard that silently stopped being picked up."
  value       = length(grafana_dashboard.this)
}

output "dashboard_urls" {
  description = "Folder title and URL for each managed dashboard."
  value = {
    for key, dash in grafana_dashboard.this :
    key => "${var.grafana_url}${dash.url}"
  }
}

output "alert_rule_count" {
  description = "Number of alert rules managed here, across every */alerts/*.yaml."
  value       = length(local.alert_rule_uids)
}
