# Grafana alerting: rules, the Discord contact point, its message template and the
# notification policy, all through the Grafana HTTP API like the dashboards.
#
# Rules live next to the component they watch, in <root>/<app>/alerts/*.yaml under apps/
# and infrastructure/. Each app directory is one rule group named after it, in the Alerts
# folder; every rule keeps Grafana's file-provisioning field names, so a rule can be
# written (or exported from the Grafana UI) in the same shape the provisioning files used.
# Terrakube clones the whole repository, so ../../ resolves from this workspace folder.

locals {
  repo_root = "${path.module}/../.."

  # "apps/nix-cache/alerts/rules.yaml", ...
  alert_files = flatten([
    for root in ["apps", "infrastructure"] : [
      for file in fileset("${local.repo_root}/${root}", "*/alerts/*.yaml") : "${root}/${file}"
    ]
  ])

  # "apps/nix-cache" => [rule, ...]. Keyed by root and app so an app name used under both
  # roots trips the precondition below instead of silently merging two groups.
  alert_groups = {
    for dir, rule_lists in {
      for file in local.alert_files :
      join("/", slice(split("/", file), 0, 2)) => yamldecode(file("${local.repo_root}/${file}")).rules...
    } : dir => flatten(rule_lists)
  }

  alert_group_names = [for dir in keys(local.alert_groups) : basename(dir)]
  alert_rule_uids   = flatten([for rules in values(local.alert_groups) : [for rule in rules : rule.uid]])

  # Every group evaluates once a minute; nothing here needs a different cadence yet.
  alert_interval_seconds = 60
}

resource "grafana_folder" "alerts" {
  uid   = "alerts"
  title = "Alerts"

  lifecycle {
    # Deleting a folder deletes every rule group inside it.
    prevent_destroy = true
  }
}

resource "grafana_rule_group" "this" {
  for_each = local.alert_groups

  name             = basename(each.key)
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = local.alert_interval_seconds

  dynamic "rule" {
    for_each = each.value
    content {
      uid            = rule.value.uid
      name           = rule.value.title
      condition      = rule.value.condition
      for            = try(rule.value["for"], "0s")
      no_data_state  = try(rule.value.noDataState, "NoData")
      exec_err_state = try(rule.value.execErrState, "Error")
      is_paused      = try(rule.value.isPaused, false)
      annotations    = try(rule.value.annotations, {})
      labels         = try(rule.value.labels, {})

      dynamic "data" {
        for_each = rule.value.data
        content {
          ref_id         = data.value.refId
          datasource_uid = data.value.datasourceUid
          model          = jsonencode(data.value.model)

          relative_time_range {
            from = data.value.relativeTimeRange.from
            to   = data.value.relativeTimeRange.to
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(distinct(local.alert_group_names)) == length(local.alert_group_names)
      error_message = "Two alerts/ directories share an app name (${join(", ", keys(local.alert_groups))}); rule group names must be unique."
    }
    precondition {
      condition     = length(distinct(local.alert_rule_uids)) == length(local.alert_rule_uids)
      error_message = "An alert rule uid is used more than once across */alerts/*.yaml."
    }
  }
}

resource "grafana_message_template" "discord" {
  name     = "discord"
  template = file("${path.module}/templates/discord.tpl")
}

resource "grafana_contact_point" "discord" {
  name = "discord"

  discord {
    url                     = var.discord_webhook_url
    title                   = "{{ template \"discord.title\" . }}"
    message                 = "{{ template \"discord.message\" . }}"
    use_discord_username    = true
    disable_resolve_message = false
  }

  # The title and message call templates defined in grafana_message_template.discord.
  depends_on = [grafana_message_template.discord]
}

# Grafana has exactly one policy tree per org; this resource owns all of it.
resource "grafana_notification_policy" "this" {
  contact_point   = grafana_contact_point.discord.name
  group_by        = ["alertname", "cluster", "namespace"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "4h"

  policy {
    contact_point   = grafana_contact_point.discord.name
    continue        = false
    group_wait      = "10s"
    group_interval  = "5m"
    repeat_interval = "12h"

    matcher {
      label = "severity"
      match = "=~"
      value = "critical|warning"
    }
  }
}
