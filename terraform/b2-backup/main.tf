# Off-site copy of the Immich library, written nightly by the immich-backup CronJob
# (apps/immich-backup). The provider authenticates from B2_APPLICATION_KEY_ID and
# B2_APPLICATION_KEY, sensitive ENV variables in the Terrakube workspace.
#
# The CronJob's own application key (listBuckets, listFiles, readFiles, writeFiles on
# this bucket, no deleteFiles) is created by hand and sealed into immich-backup-secret,
# so it never lands in this state. rclone sync can only hide files; the lifecycle rules
# below are the only thing that ever deletes data.
provider "b2" {}

# The bucket was created through the B2 API so the CronJob key could be scoped to it
# before the first apply; this adopts it.
import {
  to = b2_bucket.immich
  id = "beb346255a0c713ba5100a1e"
}

locals {
  # Days a hidden (deleted in Immich) or superseded file version is kept. Prefixes must
  # not overlap: B2 rejects a rule whose prefix starts another rule's prefix.
  retention_days = {
    "db/"      = 30
    "library/" = 90
    "profile/" = 90
    "upload/"  = 90
  }
}

resource "b2_bucket" "immich" {
  bucket_name = "jackhumes-immich-backup"
  bucket_type = "allPrivate"

  default_server_side_encryption {
    mode      = "SSE-B2"
    algorithm = "AES256"
  }

  dynamic "lifecycle_rules" {
    for_each = local.retention_days
    content {
      file_name_prefix                                       = lifecycle_rules.key
      days_from_hiding_to_deleting                           = lifecycle_rules.value
      days_from_starting_to_canceling_unfinished_large_files = 7
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
