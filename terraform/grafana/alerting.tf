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

  # One graph per rule on the generated "Alert Rules" dashboard, in uid order. A rule points
  # at its panel through the __dashboardUid__/__panelId__ annotations, which is what makes
  # Grafana attach a screenshot of it to the notification and link the panel from it.
  alert_rules         = { for uid, rules in { for rule in flatten(values(local.alert_groups)) : rule.uid => rule... } : uid => rules[0] }
  alert_panel_ids     = { for i, uid in sort(keys(local.alert_rules)) : uid => i + 1 }
  alert_dashboard_uid = "alert-rules"

  # The rule's datasource query, and the evaluator of its condition (null when it has none).
  # Every rule reduces its query with `last` and compares that against one threshold.
  alert_queries = {
    for uid, rule in local.alert_rules : uid => [for d in rule.data : d if d.datasourceUid != "__expr__"][0]
  }
  alert_evaluators = {
    for uid, rule in local.alert_rules : uid => try(
      [for d in rule.data : d if d.refId == rule.condition][0].model.conditions[0].evaluator,
      null
    )
  }
  alert_thresholds = { for uid, ev in local.alert_evaluators : uid => try(ev.params[0], null) }

  # What each graph runs. A notification is about the series that met the condition, so the
  # panel keeps only those that met it somewhere in the graph's range (`@ end()` pins that
  # check to the whole range) and draws their full history; graphing the rule's query as-is
  # drew every series it returns (40 PVCs for longhorn-backup-stale), and a query ending in
  # its own filter ("... > 0.1") only the samples past the line, as a few fragments. Such a
  # filter is dropped from what is drawn, unless the base has a top-level and/or/unless the
  # filter may bind to alone. Loki queries, and rules without a threshold, run as-is.
  alert_comparisons = {
    for uid, ev in local.alert_evaluators : uid => try(
      format("%s %s", { gt = ">", lt = "<", eq = "==" }[ev.type], ev.params[0]),
      null
    )
  }
  alert_query_bases = {
    for uid, q in local.alert_queries : uid => try(
      [for base in regex("(?s)^(.*?)(?:\\s*(?:>=|<=|==|!=|>|<)\\s*(?:[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?|[-+]?Inf))+\\s*$", q.model.expr) :
      base if !can(regex("\\b(and|or|unless)\\b", base))][0],
      q.model.expr
    )
  }
  alert_panel_exprs = {
    for uid, q in local.alert_queries : uid => (
      q.datasourceUid != "prometheus" || local.alert_comparisons[uid] == null ? q.model.expr :
      format("(%s) and max_over_time(((%s) %s)[$__range:$__interval] @ end())",
      local.alert_query_bases[uid], q.model.expr, local.alert_comparisons[uid])
    )
  }

  # Series are named by the labels the rule's own summary and description print
  # ({{ $labels.instance }} ...), so the graph matches the notification text; a rule that
  # names none has a single series and no legend.
  alert_legend_labels = {
    for uid, rule in local.alert_rules : uid => distinct(flatten([
      for key in ["summary", "description"] : [
        for m in regexall("\\$labels\\.([A-Za-z_][A-Za-z0-9_]*)", try(rule.annotations[key], "")) : m[0]
      ]
    ]))
  }
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
      annotations = merge(try(rule.value.annotations, {}), {
        __dashboardUid__ = local.alert_dashboard_uid
        __panelId__      = tostring(local.alert_panel_ids[rule.value.uid])
      })
      labels = try(rule.value.labels, {})

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

  # Grafana rejects a rule whose __dashboardUid__ points at a dashboard it does not have.
  depends_on = [grafana_dashboard.alert_rules]
}

# Generated from the rules, not from dashboards/: one timeseries per rule drawing the series
# that met its condition (see alert_panel_exprs), with its threshold as a line.
# Notifications carry a screenshot of the panel (grafana-image-renderer) and link to it.
resource "grafana_dashboard" "alert_rules" {
  folder    = grafana_folder.alerts.uid
  overwrite = true

  config_json = jsonencode({
    uid           = local.alert_dashboard_uid
    title         = "Alert Rules"
    description   = "One graph per alert rule, generated by terraform/grafana/alerting.tf from */alerts/*.yaml. Edit the rules, not this dashboard."
    tags          = ["alerts", "generated"]
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    panels = [
      for uid, id in local.alert_panel_ids : {
        id      = id
        type    = "timeseries"
        title   = local.alert_rules[uid].title
        gridPos = { h = 8, w = 12, x = ((id - 1) % 2) * 12, y = floor((id - 1) / 2) * 8 }
        datasource = {
          type = local.alert_queries[uid].datasourceUid
          uid  = local.alert_queries[uid].datasourceUid
        }
        targets = [merge({
          refId      = "A"
          expr       = local.alert_panel_exprs[uid]
          datasource = { type = local.alert_queries[uid].datasourceUid, uid = local.alert_queries[uid].datasourceUid }
          }, length(local.alert_legend_labels[uid]) == 0 ? {} : {
          legendFormat = join(" / ", [for l in local.alert_legend_labels[uid] : "{{${l}}}"])
        })]
        fieldConfig = {
          defaults = {
            custom = {
              lineWidth       = 2
              showPoints      = "never"
              thresholdsStyle = { mode = local.alert_thresholds[uid] == null ? "off" : "dashed" }
            }
            thresholds = {
              mode = "absolute"
              steps = concat([{ color = "transparent", value = null }],
              local.alert_thresholds[uid] == null ? [] : [{ color = "red", value = local.alert_thresholds[uid] }])
            }
          }
          overrides = []
        }
        options = { legend = { displayMode = "list", placement = "bottom", showLegend = length(local.alert_legend_labels[uid]) > 0 } }
      }
    ]
  })

  lifecycle {
    # alert_panel_exprs applies the condition's threshold to the query itself, which is only
    # what the rule evaluates while nothing but a reduce sits between the two.
    precondition {
      condition = alltrue([
        for rule in values(local.alert_rules) : alltrue([
          for d in rule.data : contains(["reduce", "threshold"], d.model.type) if d.datasourceUid == "__expr__"
        ])
      ])
      error_message = "An alert rule uses an expression other than reduce and threshold; teach alert_panel_exprs in alerting.tf what it means for the graph first."
    }
  }
}

resource "grafana_message_template" "discord" {
  name     = "discord"
  template = file("${path.module}/templates/discord.tpl")
}

resource "grafana_contact_point" "discord" {
  name = "discord"

  # The message is the post's text and the title its coloured embed, followed by one embed per
  # alert screenshot. use_embed_description would fold the text into that embed, but the
  # provider cannot set it: its settings map only carries strings and Grafana wants a bool.
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

resource "grafana_message_template" "gotify" {
  name     = "gotify"
  template = file("${path.module}/templates/gotify.tpl")
}

# Gotify (apps/gotify) for the Android app. A webhook posting Gotify's message JSON, built by
# the gotify.payload template: markdown text with the alert's screenshot, priority by
# severity, and the screenshot as the expanded notification's big picture. Grafana reaches
# the Service in-cluster; the screenshot URL is public (gotify.jackhumes.com/alert-images/).
resource "grafana_contact_point" "gotify" {
  name = "gotify"

  webhook {
    url                       = "http://gotify.gotify.svc.cluster.local/message"
    http_method               = "POST"
    authorization_scheme      = "Bearer"
    authorization_credentials = var.gotify_app_token
    disable_resolve_message   = false

    payload {
      template = "{{ template \"gotify.payload\" . }}"
    }
  }

  # gotify.payload reuses the title and label/link helpers from the discord template.
  depends_on = [grafana_message_template.discord, grafana_message_template.gotify]
}

# Grafana has exactly one policy tree per org; this resource owns all of it. An alert that
# is still firing is posted again every repeat_interval until it resolves.
resource "grafana_notification_policy" "this" {
  contact_point   = grafana_contact_point.discord.name
  group_by        = ["alertname", "cluster", "namespace"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "1h"

  # Every alert goes to Discord; through continue, critical ones and any rule labelled
  # notify=phone also go to the phone.
  policy {
    contact_point   = grafana_contact_point.discord.name
    continue        = true
    group_wait      = "10s"
    group_interval  = "5m"
    repeat_interval = "1h"

    matcher {
      label = "severity"
      match = "=~"
      value = "critical|warning"
    }
  }

  policy {
    contact_point   = grafana_contact_point.gotify.name
    continue        = false
    group_wait      = "10s"
    group_interval  = "5m"
    repeat_interval = "1h"

    # The phone only gets critical alerts; warnings stay on Discord.
    matcher {
      label = "severity"
      match = "="
      value = "critical"
    }
  }

  # A warning someone should act on soon without being woken, e.g. a tailnet peer stuck on
  # the relay. The gotify template gives it normal priority, so Do Not Disturb holds.
  policy {
    contact_point   = grafana_contact_point.gotify.name
    continue        = false
    group_wait      = "10s"
    group_interval  = "5m"
    repeat_interval = "1h"

    matcher {
      label = "notify"
      match = "="
      value = "phone"
    }
  }
}
