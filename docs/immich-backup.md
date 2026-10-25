# Immich off-site backup

`apps/immich-backup` copies the Immich library to Backblaze B2 every night at 04:00,
two hours after Immich writes its own database dump. The bucket is defined in
`terraform/b2-backup` (Terrakube workspace `b2-backup`).

| NAS path (`/volume1/kubernetes/media/…`) | Bucket prefix | Kept after removal |
|---|---|---|
| `library/` | `library/` | 90 days |
| `upload/` | `upload/` | 90 days |
| `profile/` | `profile/` | 90 days |
| `backups/` (Immich DB dumps) | `db/` | 30 days |

`thumbs/` and `encoded-video/` are not copied; Immich regenerates them with the
*Generate Thumbnails* and *Transcode Videos* jobs after a restore.

## How deletion works

- `rclone sync` removes a file from the bucket by **hiding** it. The file stays
  restorable until the lifecycle rule for its prefix deletes it.
- Overwriting a file keeps the previous content as an older version, which the same
  rule expires.
- The CronJob's key (`immich-backup-secret`) has no `deleteFiles` capability, so
  nothing in the cluster can delete data outright.
- `--max-delete 200` makes a run fail instead of hiding more than 200 files, for
  example when the NFS mount comes up empty.
- Grafana alert `immich-backup-stale` fires when the CronJob has not succeeded for
  48 hours.

## Monitoring

The Grafana dashboard *Immich Backup* (Media folder) shows the backup's health and bucket usage.

| Source | What it provides |
|---|---|
| kube-state-metrics | Last successful run, run duration, failed runs |
| `immich-backup-exporter` | Lists the bucket every 15 minutes. Reports stored bytes, file counts, retained (hidden or superseded) versions and newest upload per prefix, plus an estimated monthly cost |
| rclone `--metrics-addr :9250` on the job pod | Live speed and progress while a run is active |
| Loki | Job and exporter logs |

B2 itself exports no metrics, which is why the exporter exists. Its key
(`immich-backup-exporter-secret`) is limited to `listBuckets` and `listFiles`.

## Restoring

Use the backup key from the cluster. It can read, so it is enough for every restore
below.

```bash
export RCLONE_CONFIG_B2_TYPE=b2
export RCLONE_CONFIG_B2_ACCOUNT=$(kubectl -n immich get secret immich-backup-secret -o jsonpath='{.data.RCLONE_CONFIG_B2_ACCOUNT}' | base64 -d)
export RCLONE_CONFIG_B2_KEY=$(kubectl -n immich get secret immich-backup-secret -o jsonpath='{.data.RCLONE_CONFIG_B2_KEY}' | base64 -d)
B=b2:jackhumes-immich-backup

rclone lsf "$B/db/"                                 # available DB dumps
rclone copy "$B/db/<dump>.sql.gz" .                 # one dump
rclone copy "$B/library/immich/2026/2026-10-24" ./restore   # one folder
```

A file deleted or changed by mistake is still in the bucket as a hidden or older
version. To restore it, list the bucket as it was at a point in time:

```bash
rclone lsf  --b2-version-at "2026-10-20 00:00:00" "$B/library/immich/2026/"
rclone copy --b2-version-at "2026-10-20 00:00:00" "$B/library/immich/2026/2026-10-18" ./restore
```

### Losing the NAS

1. Recreate `/volume1/kubernetes/media` and copy the prefixes back into the matching
   directories: `rclone copy "$B/library" <nas>/library`, then the same for
   `upload`, `profile`, and `db` into `backups`. Downloads are free up to three times
   the stored size each month.
2. Restore the newest dump from `backups/` with Immich's
   [database restore procedure](https://immich.app/docs/administration/backup-and-restore),
   matching the Immich version in the dump's file name.
3. Start Immich, then run the thumbnail and transcode jobs.

## Rotating the keys

Create a replacement key in the B2 console with `listBuckets`, `listFiles`,
`readFiles`, and `writeFiles`, restricted to `jackhumes-immich-backup`. Seal both
values into `apps/immich-backup/sealedsecret.yaml`
(`kubeseal --raw --namespace immich --name immich-backup-secret --scope strict`),
merge the change, then delete the old key.

Rotate the exporter key the same way: create a key with only `listBuckets` and
`listFiles` on the bucket, then seal it into `apps/immich-backup/exporter-sealedsecret.yaml`
as `B2_APPLICATION_KEY_ID` and `B2_APPLICATION_KEY` (name `immich-backup-exporter-secret`).
