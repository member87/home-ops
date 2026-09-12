# Grafana dashboards, provisioned through the Grafana HTTP API instead of ConfigMaps
# and the k8s-sidecar. Each dashboards/<folder>/<name>.json is one grafana_dashboard;
# the directory name selects the Grafana folder via var.folders.
#
# Dashboard JSON is the source of truth and carries a stable "uid", so dashboard URLs
# survive this migration and any future re-apply. "id", "version" and "iteration" are
# stripped from the files on purpose: Grafana owns those and leaving them in the JSON
# makes every plan show a diff.

locals {
  # dashboards/<dir>/<file>.json relative to this module.
  dashboard_files = fileset("${path.module}/dashboards", "*/*.json")

  dashboards = {
    for file in local.dashboard_files :
    file => {
      dir  = dirname(file)
      json = file("${path.module}/dashboards/${file}")
    }
  }

  # Directories actually present on disk, so a new folder cannot be added without
  # also giving it a title in var.folders.
  dashboard_dirs = toset([for file in local.dashboard_files : dirname(file)])
}

resource "grafana_folder" "this" {
  for_each = local.dashboard_dirs

  title = lookup(
    var.folders,
    each.value,
    # Fails the plan with a readable message instead of defaulting to General.
    "MISSING_FOLDER_TITLE_FOR_${each.value}"
  )

  lifecycle {
    precondition {
      condition     = contains(keys(var.folders), each.value)
      error_message = "dashboards/${each.value}/ has no title in var.folders; add one before applying."
    }

    # The Kubernetes folder also holds the provisioned alert rules from
    # apps/grafana/alerting.yaml, and deleting a Grafana folder deletes the rules
    # inside it. Renaming a folder is an in-place update, so this only blocks an
    # actual destroy - which for a dashboards-only change is always a mistake.
    prevent_destroy = true
  }
}

resource "grafana_dashboard" "this" {
  for_each = local.dashboards

  folder      = grafana_folder.this[each.value.dir].uid
  config_json = each.value.json

  # Dashboards are code: a UI edit is overwritten on the next apply rather than
  # silently blocking it, which is the same contract the file provisioner had
  # (allowUiUpdates: false).
  overwrite = true
}
