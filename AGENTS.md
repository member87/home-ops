# Home-Ops Agent Guide

Keep this file short. Prefer discovering current details from the repo over storing long runbooks here.

## Repository

- `apps/`: plain Kubernetes manifests per application, each with a `kustomization.yaml`.
- `flux/system/`: Flux `GitRepository` and root `Kustomization` (entrypoint `./flux/cluster`).
- `flux/cluster/`: one Flux `Kustomization` per app/infra component (`apps.yaml`, `infrastructure.yaml`, `helm.yaml`).
- `flux/helm/`: `HelmRepository` plus `HelmRelease` objects for the few charts with real upstream dependencies.
- `infrastructure/`: cluster infrastructure manifests such as MetalLB, Traefik, cert-manager, Sealed Secrets, Longhorn, and CoreDNS custom hosts.
- `talos/`: SOPS-encrypted Talos configs.
- `charts/`: wrapper charts for upstream Helm dependencies.
- `scripts/validate-flux-manifests.sh`: build every path the Flux entrypoint references.
- `scripts/adopt-helmrelease.sh`: hand a release from Helm to its Kustomization without running `helm uninstall`.
- `seal-secrets.sh`: helper for Sealed Secrets.

## Core Rules

- Never commit plaintext secrets.
- Use Sealed Secrets for Kubernetes app secrets.
- Use SOPS with age for Talos configs in `talos/`.
- Pin container images to explicit versions; never use `latest`.
- Update Glance dashboard icons/links when adding or removing apps.
- When exposing a new service publicly via FRP, add the `frpc` proxy in `apps/frp-client/configmap.yaml` AND the Caddy site block in `terraform/aws-edge/launch.sh.tpl` plus the live box; see Public Access & AWS Lightsail Edge (FRP).
- Read files before editing and make targeted changes.
- Test or validate changes when feasible.
- Flux reconciles from Git; do not manually mutate cluster state unless troubleshooting or explicitly requested.
- Never commit to `main` directly. Work in a git worktree on a branch (`git worktree add ../home-ops-<topic> -b <type>/<topic>`) and land it through a pull request, so PR checks run before Flux ever sees the commit. Remove the worktree once the PR merges.

## Conventions

- Namespaces use lowercase app names, for example `pocket-id`, `tinyauth`, `netbird`.
- Deployments use `<app>` or `<app>-<component>`.
- Services usually match deployment names.
- ConfigMaps use `<app>-config` or `<app>-<component>-config`.
- Secrets use `<app>-secrets` or `<app>-<component>-secret`.
- IngressRoutes use `<app>` or `<app>-<protocol>`.
- Internal app URLs use `<app>.lab.jackhumes.com`.
- Public app URLs use `<app>.jackhumes.com` when exposed externally.
- Pocket ID is the OIDC provider. Tiny Auth is used as ForwardAuth for apps without native OIDC.
- Apps and infrastructure are plain manifests applied by a per-component Flux `Kustomization`; there are no per-app wrapper charts. Only charts with a real upstream dependency stay `HelmRelease`s: `apps/immich`, `apps/pihole`, `apps/podinfo`, `charts/cert-manager`, `infrastructure/longhorn` (Git-sourced) and `radar` (skyhook `HelmRepository`), one `Kustomization` each under `flux/helm/<name>`.
- Git-sourced `HelmRelease`s use `reconcileStrategy: ChartVersion`: changing files in those chart dirs only deploys when `Chart.yaml` `version` is bumped. `scripts/validate-flux-manifests.sh` fails the build if you forget. Values live in the `HelmRelease` `spec.values`, where edits deploy immediately.
- Each `HelmRelease` carries `kustomize.toolkit.fluxcd.io/prune: disabled`: pruning one would make helm-controller uninstall the release and delete its PVCs.
- Kustomization-managed components have no automatic rollback (Helm remediation is gone for them): a bad manifest stays applied and is fixed forward. Leaf reconcile interval is 15m; a git push still reconciles immediately.

## Secrets

- Seal passwords, API keys, tokens, OAuth/OIDC client secrets, HMAC/JWT/session secrets, private keys, encryption keys, and credential-bearing connection strings.
- Public URLs, ports, hostnames, feature flags, log levels, and non-sensitive settings can live in ConfigMaps.
- SOPS age key: `~/.config/sops/age/keys.txt`.
- SOPS public key is in `.sops.yaml`; the private key must be backed up outside the repo.
- `talos/talosconfig` needs explicit YAML type flags when using `sops` directly.

Common commands:

```bash
kubeseal --fetch-cert --controller-namespace=sealed-secrets --controller-name=sealed-secrets-controller > /tmp/pub-cert.pem
echo -n 'secret-value' | kubeseal --raw --cert=/tmp/pub-cert.pem --from-file=/dev/stdin --namespace <namespace> --name <secret-name> --scope strict
just talos-edit controlplane.yaml
just talos-decrypt controlplane.yaml
sops --input-type yaml --output-type yaml talos/talosconfig
```

## Adding Or Updating Apps

- Put app resources under `apps/<app-name>/`.
- Typical files: `namespace.yaml`, `deployment.yaml`, `service.yaml`, `configmap.yaml`, `sealedsecret.yaml`, `ingressroute.yaml`, `kustomization.yaml`.
- Every hand-written manifest carries an explicit `metadata.namespace`; the only namespace transformers are `apps/{glance,ip-checker,nas}`, and glance/headscale need theirs because generated ConfigMaps have no namespace of their own. `kustomization.yaml` must reference every file in the directory.
- Add a Flux `Kustomization` for the app in `flux/cluster/apps.yaml`, then run `scripts/validate-flux-manifests.sh`.
- Only reach for a `HelmRelease` in `flux/helm/` when the app needs an upstream chart.
- Use health checks where supported. Use TCP probes when no HTTP health endpoint exists.
- For OIDC apps, create a Pocket ID client and seal the client secret.
- For non-OIDC apps, add Tiny Auth ForwardAuth middleware.
- Only add Grafana dashboards or app alerts when the app exposes Prometheus metrics or has a real exporter.

## Helm To Kustomize Cutover (one-off, in progress)

The live root `Kustomization` was applied by `bootstrap.sh`, not reconciled from Git, so the
entrypoint move to `./flux/cluster` must be applied by hand once. Until step 1 runs, Flux is
still trying to build the deleted `./flux/apps`.

```bash
# 0. preconditions: all nodes Ready, and no HelmRelease left in a failed/rollback state.
#    A failing release keeps retrying remediation, so it would fight the new Kustomization
#    over the same objects (Helm converging backwards, SSA converging forwards) until it is
#    adopted. Fix it or suspend it first. Healthy releases do not fight: drift detection is
#    off by default, so helm-controller only re-applies on a chart/values change.
flux get helmreleases -A | grep -v True       # must be empty before merging
# Merging re-upgrades the five Git-sourced charts once (version bump + values move).
# Rendered output is unchanged, but Longhorn runs chart hooks on any upgrade, so watch it:
#   kubectl -n longhorn-system get pods -w -l longhorn.io/component=instance-manager
# `flux suspend` does NOT hold here - kustomize-controller re-applies spec.suspend from
# Git. To genuinely hold a release back, commit `suspend: true` in flux/helm/<name>.
# 1. deliver the new entrypoint (one time; afterwards the flux-system Kustomization owns it)
kubectl apply -k flux/system
flux reconcile kustomization home-ops --with-source
scripts/validate-flux-manifests.sh
flux get kustomizations -A                    # expect 56 Ready
# 2. adopt each component: dry run, then apply. Stateless first, PVC-backed apps last.
scripts/adopt-helmrelease.sh ttyd
scripts/adopt-helmrelease.sh ttyd --apply
# 3. after every release is adopted
scripts/adopt-helmrelease.sh <name> --apply --purge-history
# generated-ConfigMap renames leave the old fixed-name objects owned by nothing
kubectl -n glance delete configmap glance-config
kubectl -n headscale delete configmap headscale-config
```

Final step, in a follow-up PR: flip the root `Kustomization` to `prune: true` (kept `false`
for the cutover so nothing can be deleted), and move the raw manifests still inside the five
Git-sourced chart dirs out to their own Kustomizations - their `helm.sh/resource-policy: keep`
annotations are the prerequisite that makes that safe.
## Public Access & AWS Lightsail Edge (FRP)

External access for `<app>.jackhumes.com` is routed through the AWS Lightsail edge (`18.171.34.111`, built by `terraform/aws-edge`) over FRP. Full chain: client -> Caddy (TLS) -> frps remote port -> frpc tunnel -> Traefik -> app IngressRoute.

Three places must agree when exposing a new public service (the cluster side alone is not enough):
1. `apps/frp-client/configmap.yaml` — add a `[[proxies]]` TCP entry whose `remotePort` forwards to Traefik `:80`.
2. `terraform/aws-edge/launch.sh.tpl` — add the Caddy site block reverse-proxying the host to `localhost:<remotePort>`. This is the source of truth, but it only runs on first boot: `user_data` carries `lifecycle { ignore_changes = [user_data] }` so editing it never replaces the live instance. Roll the same block onto the running box over SSH (below).
3. Cloudflare DNS — an A record for the host pointing at the edge IP, managed by `terraform/aws-edge-dns` (`public_hostnames`). Keep proxying off: ACME HTTP-01 and DERP need the real IP.

Tunnel map:

|Host|frpc remotePort|Target|
|---|---|---|
|`auth.jackhumes.com`|`8081`|Traefik -> Pocket ID|
|`headscale.jackhumes.com`|`8082`|Headscale (direct)|
|`dawarich.jackhumes.com`|`8083`|Traefik -> Dawarich|
|`terrakube-hook.jackhumes.com`|`8084`|Traefik -> Terrakube webhook gatekeeper|

### SSH to the edge

```bash
ssh ubuntu@18.171.34.111        # key-based; prefix system/docker commands with sudo
```

Caddy and frps run in Docker (compose project `frp-tunnel` in `/opt/frp-tunnel`). After editing `/opt/frp-tunnel/Caddyfile`, validate and reload without downtime:

```bash
sudo docker exec caddy caddy validate --config /etc/caddy/Caddyfile
sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Keep the edge patched with `just update-vps` (optional reboot with `just update-vps yes`).

## Terrakube IaC Pipeline

Everything under `terraform/` is planned and applied by Terrakube in-cluster. There are no GitHub Actions: GitHub only delivers webhooks, and all execution happens in the `terrakube` namespace.

- Organization `homeops`; workspace `aws-edge` -> `terraform/aws-edge` on `main`, OpenTofu, remote execution. State lives in Terrakube (MinIO-backed), never in a local `terraform.tfstate`.
- Pull request -> `Plan` template. Push to `main` -> `Plan and apply`. Both carry a file filter so only changes under the workspace's directory trigger a run.
- Terrakube posts the plan as a pull request comment and sets a GitHub commit status (`pending` -> `success`/`failure`), which is what branch protection requires to block a pull request with a failing plan. `terrakube plan` re-runs a plan from a comment; apply-via-comment is deliberately off.
- Secrets (AWS keys, `frps_auth_token`, `frps_dashboard_password`, `tailscale_authkey`) are sensitive workspace variables in Terrakube, not files in this repo.

### Why the webhook gatekeeper exists

This repo is public and Terrakube has no fork awareness, so a pull request from any fork would otherwise run `tofu plan` in the executor with those credentials in scope. `apps/terrakube/webhook-gate*.yaml` is a small service that GitHub talks to instead of the API. It verifies the `X-Hub-Signature-256` HMAC and forwards only:

- `push` to `main` in `member87/home-ops`,
- `pull_request` (opened/synchronize/reopened) whose head repo equals the base repo — every fork is dropped,
- `issue_comment` from an allowlisted login.

Anything else gets a `202` and goes no further. It is the only Terrakube component reachable from the internet (`terrakube-hook.jackhumes.com`, frp remote port `8084`); the UI and API stay on the LAN. The HMAC secret is the one Terrakube generated when registering the webhook, sealed into `terrakube-webhook-gate-secret` so both sides verify the same signature.

### Webhook event rules

The webhook (`092e7d85-af89-410d-9b6e-65623fc16676`) carries three event rules, set through the API because the UI cannot express all of them. They are matched in `priority` order and the first match wins:

| Priority | Event | Branch | Path | Template |
| --- | --- | --- | --- | --- |
| 1 | `PUSH` | `main` | `terraform/aws-edge/*` | Plan and apply |
| 1 | `PULL_REQUEST` | `.*` | `terraform/aws-edge/*` | Plan |
| 2 | `PULL_REQUEST` | `.*` | `**` | No IaC changes ack |

Two things about this are easy to get wrong:

- **`branch` is a Java regex, not a branch name**, and for a `pull_request` event Terrakube matches it against the *head* branch. A pull-request rule with `branch: main` therefore never fires — it silently logs `No valid template found for webhook event pull_request` and no job is created. Pull-request rules must use `.*`.
- **The priority-2 rule exists to keep branch protection satisfiable.** `main` requires the status check `Terrakube - homeops - aws-edge`, and GitHub blocks a pull request forever if a required check never reports. A pull request touching no terraform would never get a status, so the fallback rule runs a `customScripts` template that does nothing but report success. It has `prWorkflowEnabled: false`, so it posts no comment.

Branch protection on `main`: required status check `Terrakube - homeops - aws-edge`, `enforce_admins` on, no force pushes, no deletions. A failed plan leaves the pull request `mergeable_state: blocked` and merging returns HTTP 405 even for an admin.

### Known upstream defect: duplicated plan comments

Every plan posts its comment and commit status twice. It is cosmetic — terraform runs once — and there is no configuration that disables it.

A job's Quartz context is created under the canonical key `TerrakubeV2_Job_<id>`, while `JobManageHook` status changes schedule extra one-shot contexts named `TerrakubeV2_Job_<id>_<uuid>`. `ScheduleJob.removeJobContext` deletes only whichever key fired, so when a one-shot handles completion the canonical repeating trigger survives, fires once more, and re-runs the completion path — which calls `PrCommentService.postPlanResult` and `sendCommitStatus` again with no idempotency guard. `JobReconciliationSweep.reconcileTrigger` recreates the canonical trigger unconditionally, so `sweepEnabled: false` does not help.

### Comments are posted by the connected VCS identity

Plan comments and commit statuses appear as whichever GitHub identity the VCS connection authenticated as — currently the `member87` user via OAuth, so plans look like they were written by a human. Terrakube also supports `VcsConnectionType.STANDALONE`, where the connection holds a GitHub App's id and private key and `ScheduleGitHubAppToken` refreshes per-installation tokens; comments then come from `<app-name>[bot]`. Switching requires creating a GitHub App by hand, since GitHub has no API for creating one.

## Monitoring

- Monitoring stack includes Prometheus, Grafana, Loki, Alloy, kube-state-metrics, node-exporter, and Discord alerting.
- Alloy replaces Promtail; do not add Promtail.
- Grafana dashboards are ConfigMaps labeled `grafana_dashboard: "1"`.
- Use `grafana_folder` annotations for dashboard folders.
- Avoid alert fatigue. Add alerts only for actionable service availability, high error rate, severe latency, resource exhaustion, data integrity, or security issues.
- Existing cluster alerts already cover basic pod health, restarts, CPU, memory, and disk.

## Cluster Facts

- Platform: Talos Linux, Kubernetes v1.34+.
- Base domain: `lab.jackhumes.com`.
- Auth server: `auth.jackhumes.com` externally and `auth.lab.jackhumes.com` internally.
- Flux namespace: `flux-system`.
- Sealed Secrets namespace: `sealed-secrets`.
- Longhorn is the default replicated storage class.
- Direct NFS is used for media/download storage from NAS `10.0.0.9`.
- Use `longhorn` for app config, databases, and monitoring data.
- Use `nfs-manual` or direct NFS PVs only for shared media/download data.
- NAS paths: `/volume1/kubernetes/media`, `/volume1/kubernetes/downloads`, and Longhorn backups at `/volume1/kubernetes/longhorn-backups`.
- MetalLB address pool is `10.0.0.200-10.0.0.250`.
- External access uses FRP through the AWS Lightsail edge (`18.171.34.111`); see Public Access & AWS Lightsail Edge (FRP) for the full chain, tunnel map, and SSH steps.
- Public traffic for `auth.jackhumes.com` and `dawarich.jackhumes.com` must route through Traefik so CrowdSec can block banned IPs.
- FRP remote ports: Pocket ID `8081` (via Traefik), Headscale `8082` (direct to `headscale.headscale.svc:8080`), Dawarich `8083` (via Traefik), Terrakube webhook gate `8084` (via Traefik).
- Headscale public URL is `https://headscale.jackhumes.com`.
- Headscale internal URL is `https://headscale.lab.jackhumes.com`.
- Home Assistant runs Home Assistant, OTBR, and Matter Server together and uses `hostNetwork`; preserve the Thread dataset because losing it requires factory-resetting Thread devices.
- Terrakube (`terrakube.lab.jackhumes.com`) runs the OpenTofu plan/apply pipeline for `terraform/`; see Terrakube IaC Pipeline.

Important IPs:

| IP | Purpose |
| --- | --- |
| `18.171.34.111` | AWS Lightsail edge / FRP server |
| `10.0.0.200` | Traefik LoadBalancer |
| `10.0.0.201` | Pi-hole DNS |
| `100.64.0.0/10` | Headscale Tailnet IPv4 range |

## Common Commands

```bash
flux get all -A
flux reconcile source git home-ops -n flux-system
flux reconcile kustomization home-ops -n flux-system --with-source
flux reconcile helmrelease <app-name> -n flux-system --with-source
kubectl get pods -n <namespace>
kubectl logs -n <namespace> <pod-name> --tail=50
kubectl describe pod -n <namespace> <pod-name>
kubectl port-forward -n <namespace> svc/<service> <local-port>:<remote-port>
just help
just talos-status
```

## Troubleshooting Pointers

- App not syncing: check Flux root kustomization and the app `HelmRelease`, then reconcile source and kustomization.
- Pod not starting: check pod status, events, current logs, and previous logs for crashed pods.
- SealedSecret not unsealing: verify namespace/name, controller cert, generated Secret, and controller logs.
- OIDC failing: check redirect URI, client secret, supported scopes, audience, Pocket ID logs, and Tiny Auth logs if ForwardAuth is involved.
- cAdvisor missing on Talos: Prometheus may need kubelet TLS `insecure_skip_verify: true` and RBAC for `nodes/metrics` plus `/metrics/cadvisor`.
- CrowdSec not blocking: ensure external FRP traffic reaches Traefik, the IngressRoute has the bouncer middleware, and the bouncer is registered with LAPI.
- Grafana dashboard stale: check Flux status, dashboard ConfigMap, dashboard sidecar logs, and Grafana folder annotations.
- Loki duplicate logs: filter queries to a single log collection job.

### A Traefik Replica Serving 404 For Every Route On One Entrypoint

- Symptom: a host 404s roughly half the time. `auth.jackhumes.com` and `dawarich.jackhumes.com` 404'd while `headscale.jackhumes.com` (which bypasses Traefik) was fine, and Pocket ID answered 200 from inside the cluster.
- Diagnose: curl each Traefik pod IP directly with a `Host:` header. One replica answered 200 and the other 404 for the same request, while `/api/http/routers` on both reported an identical 64-router config - the router tree for the `web` entrypoint was never built. The bad pod had restarted 7 times during an apiserver outage.
- Fix: `kubectl -n traefik delete pod <replica>`; it rebuilds its config on start.
- Related trap: a client using a public resolver bypasses Pi-hole's `*.lab.jackhumes.com` wildcard and hits the public edge, which 404s for internal-only hosts. Test internal hosts with `curl --resolve <host>:443:10.0.0.200`.

### Renovate Bumped An Image Inside A Vendored Upstream Manifest

- Symptom: MetalLB speaker failed liveness with `statuscode: 400`, the release rollback-looped, and everything behind it (metallb-config, pihole, therefore LAN DNS) stayed NotReady.
- Cause: `infrastructure/*/install.yaml` are complete upstream manifests vendored whole. Renovate rewrote only the `image:` tags to v0.16.1, so 0.16 images ran against 0.15 plumbing (`/metrics` on 7472 over HTTP vs upstream's `/healthz` on 17472).
- Fix: pin the images back to the vendored manifest's version. Renovate is now disabled for those files; upgrading means re-vendoring the whole manifest.

### Pi-hole Deployed With Chart Defaults (LAN DNS Dies)

- Symptom: `pihole-dns-tcp`/`-udp` appear as NodePort, `10.0.0.201` disappears, and nothing in the cluster can resolve external names because CoreDNS forwards to `10.0.0.201`. Chart dependency fetches then fail too, so Flux cannot fix it - break the loop by patching the Services back to `type: LoadBalancer` with `loadBalancerIP: 10.0.0.201` and the `metallb.universe.tf/allow-shared-ip: pihole-svc` annotation.
- Cause: the release was reconciled while its values were missing (values live in the `HelmRelease` `spec.values`, not in the chart dir). A values-less Pi-hole release means NodePort services and no `*.lab.jackhumes.com` wildcard.
### Leaked VPN Kill Switch On A Node

- Symptom: host-originated egress is dead on one or more nodes. Image pulls time out, `talosctl dmesg` logs `write: operation not permitted` for NTP, and off-LAN TCP is blackholed while `10.0.0.0/24` still works.
- Diagnose: from a privileged `hostNetwork` pod on the node, `iptables-nft -L -n` shows filter `INPUT`/`OUTPUT`/`FORWARD` policy `DROP` with a gluetun allowlist: `lo`, `ESTABLISHED`, LAN/pod/service CIDRs, ProtonVPN endpoints on `udp/51820`, and a `-o tun0` rule for an interface that does not exist on the host.
- Fix: set the three policies back to `ACCEPT` and delete only the leaked gluetun rules; keep the `KUBE-FIREWALL` and `FLANNEL-FWD` jumps intact.
- Prevent: exit-node pods must never use `hostNetwork` — gluetun's kill switch then writes into the host netns and survives pod deletion. The `exit-node-manager-deny-hostnetwork` ValidatingAdmissionPolicy enforces this in the `tailscale-exit-node-manager` namespace; gluetun's firewall inside its own pod netns is correct and stays on.
## Commit Style

Use concise conventional commits:

```text
feat(<scope>): add <thing>
fix(<scope>): resolve <problem>
docs(<scope>): update <topic>
chore(<scope>): perform maintenance
```
