# etcd snapshots

`infrastructure/etcd-backup` takes a snapshot of etcd every night at 03:30 (Europe/London)
and writes it to the NAS as `/volume1/kubernetes/etcd-backups/etcd-snapshot-<UTC time>.db`,
keeping the newest 14. etcd holds every Kubernetes object, so with the Git repository and
the Longhorn backups this is what a lost control plane is rebuilt from. It does not hold
volume data.

## How it works

- The talos.dev `ServiceAccount` `etcd-snapshot` gets a Talos client certificate with the
  `os:etcd:backup` role only: it can take snapshots and nothing else. Talos issues it only
  because `talos/patches/etcd-backup-api-access.yaml` is on every node.
- The CronJob's `talosctl` container asks the control plane (Service `default/talos`) for a
  snapshot of the node the pod runs on (`--nodes` from `status.hostIP`; every node is a
  control-plane node); a busybox container copies it to the NAS and deletes the oldest
  beyond 14. A run succeeds only once the file is on the NAS.
- The `talosctl` image follows `siderolabs/talos` in the Talos and Kubernetes pull request.

## Monitoring

Jevil reads the CronJob's last successful run every hour (`backups.etcd` in
`apps/jevil/policy.json`): the daily report's **etcd snapshots** line, and
`jevil_etcd_snapshot_age_seconds` (`+Inf` when the CronJob does not exist). Grafana alert
`etcd-snapshot-stale` fires when it is over 36 hours.

## Taking one by hand

```bash
just _talosctl -n 10.0.0.10 etcd snapshot backups/etcd-snapshot-$(date -u +%Y%m%d-%H%M%S).db
```

`backups/` is git-ignored.

## Restore

Only when etcd has lost quorum and cannot recover (a single failed member is replaced by
resetting that node, not by a restore). Follow Talos' disaster recovery guide
(<https://docs.siderolabs.com/talos/latest/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery>):

1. Copy the newest `etcd-snapshot-*.db` from `/volume1/kubernetes/etcd-backups` to this machine.
2. On every control-plane node whose etcd is not in `Preparing`, wipe etcd's data:
   `just _talosctl -n <node-ip> reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL`.
3. When `just _talosctl -n <node-ip> service etcd` shows `Preparing` on every node, restore on
   one of them: `just _talosctl -n 10.0.0.10 bootstrap --recover-from=./etcd-snapshot-<time>.db`.
   The others join it.
4. Flux reconciles anything changed in Git since the snapshot.
