# Adopts the folders that already exist in Grafana instead of creating new ones.
#
# These five folders were created by the old file-structure dashboard provisioner
# (foldersFromFilesStructure), and the Kubernetes folder is also where the provisioned
# alert rules in apps/grafana/alerting.yaml live. Creating them fresh would fail on the
# duplicate title, and deleting them to let Terraform recreate them would take those
# alert rules with them.
#
# Import blocks run inside the normal plan/apply, so no local state surgery is needed.
# They are safe to remove once the state has them; a follow-up change does that.

import {
  to = grafana_folder.this["kubernetes"]
  id = "ffcv79783iolce"
}

import {
  to = grafana_folder.this["logs"]
  id = "dfcv79bemeepse"
}

import {
  to = grafana_folder.this["network"]
  id = "afcv798wdkgzka"
}

import {
  to = grafana_folder.this["security"]
  id = "bfcv79fnn6ha8c"
}

import {
  to = grafana_folder.this["unifi"]
  id = "afcv79bm1ljpca"
}
