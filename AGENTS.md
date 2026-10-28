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
- Talos and Kubernetes upgrades run through tuppr (`flux/helm/tuppr`, CRs in `infrastructure/tuppr`): `TalosUpgrade cluster` and `KubernetesUpgrade kubernetes` hold the versions the nodes run, and merging a change to them upgrades the cluster. Renovate opens one "Talos and Kubernetes" PR (branch `renovate/talos-and-kubernetes`) that bumps both CRs plus the installer and Kubernetes images in `talos/*.yaml`, never automerged. Watch a rollout with `kubectl get talosupgrade,kubernetesupgrade -w` and `kubectl describe talosupgrade cluster`.
  - **Ordering:** Flux applies the KubernetesUpgrade only after `tuppr-talos` is Ready, i.e. the TalosUpgrade Completed, so Talos always finishes first.
  - **Steps:** Talos must go through every minor and `upgrade-k8s` one Kubernetes minor at a time, and tuppr does not enforce either. Renovate proposes the lowest safe step (latest patch of the current minor, then the next minor; `separateMultipleMinor` on one fixed branch). Kubernetes is capped by `allowedVersions` in `renovate.json` at what the running Talos minor supports (Talos 1.14: Kubernetes 1.33-1.37); raise it in the same PR as the Talos minor that supports more, and keep `K8S_RANGE` in `scripts/talos-sync.sh` in step.
  - **Gates:** before each node, every node Ready and every attached Longhorn volume healthy. tuppr's CEL sees only an object's `status`; an expression that reads `spec` fails validation and parks the run in `HealthChecking` indefinitely, so the replica count cannot be checked there (a node holding an attached volume's only replica cannot drain anyway). talosctl drains each node during its upgrade (`waitForVolumeDetach` stays off: it hands the drain to tuppr, whose drain gives up on the first PDB-refused eviction and loops in `Draining`); Longhorn releases the node's instance-manager PDB only once its volumes detach, so the reboot waits for that, and the upgrade fails without rebooting if the drain exceeds 35m (qbittorrent's grace period is 30m).
  - **Image:** tuppr version-swaps each node's live `machine.install.image`, so that must stay `factory.talos.dev/metal-installer/<schematic>:...` with the schematic the node runs, or tuppr refuses the node. Talos upgrades do not update it themselves.
  - **Talos API access:** `talos/patches/tuppr-api-access.yaml` grants `system-upgrade` `os:admin`; it must be on every node, including any new one.
  - **Not covered by tuppr, check before merging a Talos minor:** patches a new Talos needs *before* its first boot (like `talos/patches/time-sync.yaml` for 1.14) must be applied first with `just talos-patch <node-ip> <file>` on every node. tuppr has no system-disk latency gate (etcd shares the disk with Longhorn); the Longhorn healthy check covers the rebuild load that caused it.
  - `upgrade-k8s` overwrites the CoreDNS Corefile; the `coredns` Kustomization re-applies `infrastructure/coredns` every 5m.
- `just talos-drift` (read-only) compares nodes with `talos/controlplane.yaml`. `just talos-sync` is the manual break-glass path when tuppr cannot run; it does the same job with stricter pre-flight checks. Do not `just talos-apply` the full file for a small change; put plaintext, secret-free documents in `talos/patches/`, written for the running Talos version, and apply them with `just talos-patch <node-ip> <file>` (`--dry-run` first).
- Before `just talos-sync` (manual path only):
  - **Network path:** reach `10.0.0.0/24` over the LAN (`tailscale set --accept-routes=false` on the workstation), not through the in-cluster Tailscale subnet router. That router is pinned to lox, so draining lox cuts the session mid-upgrade.
  - **Kubeconfig:** point it at the control-plane VIP `https://10.0.0.15:6443`, not one node.
  - **Reasons for the script's other steps:** Talos 1.14 cold boots hang until time syncs, and IPv6 NTP gets no answer here, so `talos/patches/time-sync.yaml` must be on a node before it first boots 1.14; the script applies accepted patches early. `upgrade-k8s` overwrites the CoreDNS Corefile, and the script re-applies `infrastructure/coredns`. A zero-disruption PDB blocks drains; the pre-flight names it.
- No swap on the nodes: Talos only supports swap partitions, and EPHEMERAL fills each node's single disk.
- Pin container images to explicit versions; never use `latest`.
- Update Glance dashboard icons/links when adding or removing apps.
- When exposing a new service publicly via FRP, add the `frpc` proxy in `apps/frp-client/configmap.yaml` and the Caddy site block in `terraform/aws-edge/config/Caddyfile`; see Public Access & AWS Lightsail Edge (FRP).
- Read files before editing and make targeted changes.
- Test or validate changes when feasible.
- Flux reconciles from Git; do not manually mutate cluster state unless troubleshooting or explicitly requested.
- Never commit to `main` directly. Work in a git worktree on a branch (`git worktree add ../home-ops-<topic> -b <type>/<topic>`) and open a pull request, so PR checks run before Flux ever sees the commit. Remove the worktree once the PR merges.
- **Merge only with `/jevil merge`.** The GitHub merge button and `gh pr merge` are blocked: the `jevil-merges-only` ruleset lets nothing but the Jevil Bot App update `main`. Comment `/jevil merge` on the pull request (only logins in `commanders` in `apps/jevil/policy.json`); Jevil queues it at its current head, checks readiness one last time (same head, not draft or held, no conflict, no failing check, required Terrakube checks green), merges it (squash), waits until every Flux Kustomization or Terrakube workspace it touches has applied it, and comments that it is live. A push after the command dequeues it; comment again. `/jevil cancel` dequeues. It works like the Aviator merge queue, one pull request at a time, and Jevil's own `review` ruling does not block a commanded merge: the command is the human decision. Break-glass when Jevil is down: an admin disables the ruleset in Settings → Rules, merges, and re-enables it.
- Every open pull request carries a Jevil **"what this changes"** comment: each Flux Kustomization, Git-sourced HelmRelease (deploys only on a `Chart.yaml` version bump), Terrakube workspace and new app it deploys, with the files under each, and what nothing deploys. Read it before `/jevil merge`; the post-merge "live" check waits for exactly those targets.
- Jevil also runs pre-merge checks on every pull request head (`jevil/checks` status; the table is in the same comment): `secret`, `validate` (kustomize build + kubeconform), `lint` (the rules in this file: memory limits, pinned images, explicit namespaces, `kustomization.yaml` completeness, `Chart.yaml` bumps, Longhorn image overrides, Glance and Prometheus keep-list warnings), `destructive` (removed PVCs/Namespaces/HelmReleases/CRDs, immutable fields, dropped `prune: disabled`) and `image` (the new tag exists). A blocking finding stops `/jevil merge`; after review, `/jevil merge --allow <checks>` accepts it. `/jevil merge` also waits while the cluster is unhealthy (a node NotReady, a degraded attached Longhorn volume, a tuppr upgrade not `Completed`, a failing Kustomization the PR does not touch); `--allow health` overrides. Mark a false secret hit with `jevil:allow` in a comment on that line. `/jevil revert` on a merged PR opens and queues the revert. Details: `docs/jevil.md`.

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
- Every hand-written manifest carries an explicit `metadata.namespace`; the only namespace transformers are `apps/{frp-client,glance,headscale,ip-checker,nas}`, where generated ConfigMaps need the transformer to receive a namespace. `kustomization.yaml` must reference every file in the directory.
- Add a Flux `Kustomization` for the app in `flux/cluster/apps.yaml`, then run `scripts/validate-flux-manifests.sh`.
- Only reach for a `HelmRelease` in `flux/helm/` when the app needs an upstream chart.
- Use health checks where supported. Use TCP probes when no HTTP health endpoint exists.
- Give every application container a memory limit, init containers included. The Talos OOM ranking (`talos/patches/oom-config.yaml`) kills limited pods first and treats pods without a limit as infrastructure (Longhorn instance-manager, kube-apiserver), killed last. An app without a limit silently joins that protected tier. For Helm wrapper charts, values go under the dependency key, e.g. `values.podinfo.resources`.
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
2. `terraform/aws-edge/config/Caddyfile` — add the site block reverse-proxying the host to `localhost:<remotePort>`. Terrakube deploys and validates the edge config over SSH after merge; never edit the live file as the source of truth.
3. Cloudflare DNS — an A record for the host pointing at the edge IP, managed by `terraform/aws-edge-dns` (`public_hostnames`). Keep proxying off: ACME HTTP-01 and DERP need the real IP.

Tunnel map:

|Host|frpc remotePort|Target|
|---|---|---|
|`auth.jackhumes.com`|`8081`|Traefik -> Pocket ID|
|`headscale.jackhumes.com`|`8082`|Headscale (direct)|
|`terrakube-hook.jackhumes.com`|`8084`|Traefik -> Terrakube webhook gatekeeper|
|Edge-local metrics receiver|`9091`|Prometheus remote-write API; bound to loopback and closed by the Lightsail firewall|

### SSH to the edge

```bash
ssh ubuntu@100.64.0.21          # tailnet address; reachable from tailnet clients and the 10.0.0.0/24 LAN, not 192.168.1.0/24. Key-based; prefix system/docker commands with sudo
```

Public 22/tcp is open only to Lightsail browser SSH (`lightsail-connect`), the break-glass path if tailscale on the box is down. Terrakube's provisioner also SSHes over the tailnet (`edge_tailnet_ip`), so the home WAN IP, which changes daily, never goes in git. Rebuilding the instance registers a new Headscale node with a new address: update `edge_tailnet_ip` from `headscale nodes list`.

Caddy, FRP, node-exporter, and the Prometheus agent are managed by the `terraform_data.edge_config` resource from files under `terraform/aws-edge/config/`. Terrakube validates and deploys those files over SSH, then recreates the Compose services. Manual edits under `/opt/frp-tunnel` are overwritten by the next applicable Terraform run.

Keep the edge patched with `just update-vps` (optional reboot with `just update-vps yes`).

## Terrakube IaC Pipeline

Everything under `terraform/` is planned and applied by Terrakube in-cluster. There are no GitHub Actions: GitHub only delivers webhooks, and all execution happens in the `terrakube` namespace.

- Organization `homeops`. Three workspaces, each with its own state, webhook and commit-status context:
  - `aws-edge` -> `terraform/aws-edge`, the Lightsail edge box and its FRP/Caddy config.
  - `grafana` -> `terraform/grafana`, every Grafana dashboard and folder.
  - `b2-backup` -> `terraform/b2-backup`, the Backblaze B2 bucket for the Immich off-site backup. Provider credentials are the sensitive ENV variables `B2_APPLICATION_KEY_ID`/`B2_APPLICATION_KEY`.
- All are OpenTofu with remote execution, so `iacType` must be `tofu`; setting it to `terraform` with an OpenTofu version fails the job with "Invalid Terraform version range". State lives in Terrakube (MinIO-backed), never in a local `terraform.tfstate`.
- Each workspace registers its own GitHub webhook, and the v1 HMAC secret is `base64(workspaceId)`, so the gatekeeper takes a comma-separated `GITHUB_WEBHOOK_SECRETS` and accepts any of them. Adding a workspace means adding its secret there too, bumping `checksum/secrets` in `apps/terrakube/webhook-gate.yaml` so the gate restarts with it (plus the `apps/terrakube/Chart.yaml` version, or the change never deploys), and pointing the new GitHub hook at `https://terrakube-hook.jackhumes.com/webhook/v1/<webhookId>` (Terrakube registers it with the LAN-only API URL).
- Pull request -> `Plan` template. Push to `main` -> `Plan and apply`. Both carry a file filter so only changes under the workspace's directory trigger a run.
- Terrakube posts the plan as a pull request comment and sets a GitHub commit status (`pending` -> `success`/`failure`), which is what branch protection requires to block a pull request with a failing plan. `terrakube plan` re-runs a plan from a comment; apply-via-comment is deliberately off.
- Secrets (`frps_auth_token`, `frps_dashboard_password`, `tailscale_authkey`, and AWS credentials) are sensitive workspace variables in Terrakube, not files in this repo. Terraform generates the edge deployment and host SSH identities into sensitive state; state access therefore grants edge SSH access. Additional operator public keys live in `admin_ssh_public_keys` without labels.

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

### VCS auth is a GitHub App, not a user

Plans are posted by `terrakube-homeops-bot[bot]` — both the pull request comment and the commit status. The VCS connection is `terrakube-homeops-bot (GitHub App)`, `connectionType: STANDALONE`, holding the App's client id and PKCS#8 private key; `GitHubTokenService` signs an RS256 JWT with it, resolves the installation through `/repos/member87/home-ops/installation`, and caches per-installation tokens that `ScheduleGitHubAppToken` refreshes hourly. There is no user OAuth token in the database any more.

Three things will bite whoever touches this next:

- **The key must be PKCS#8.** GitHub hands out PKCS#1 (`BEGIN RSA PRIVATE KEY`); `generateJWT` strips only `-----BEGIN PRIVATE KEY-----` and feeds the rest to `PKCS8EncodedKeySpec`, so an unconverted key throws `InvalidKeySpecException`. Convert with `openssl pkcs8 -topk8 -nocrypt`.
- **`Issues: write` is required, not just `Pull requests: write`.** Plan comments go to `/repos/{owner}/{repo}/issues/{n}/comments` and the acknowledgement reaction to `/issues/comments/{id}/reactions`. The App needs Contents read, Metadata read, Pull requests write, Issues write, Commit statuses write, and Repository hooks write (Terrakube maintains the repo webhook itself).
- **The App's own webhook is deliberately disabled.** Deliveries must come from the repository webhook that points at the gatekeeper; an App-level webhook would deliver a second, ungated copy straight to the API.

The private key exists only in the Terrakube database and wherever it was backed up — it is not in this repo and cannot be recovered from GitHub. Generate a fresh one from the App settings if it is ever lost.

## Monitoring

- Monitoring stack includes Prometheus, Grafana, Loki, Alloy, kube-state-metrics, node-exporter, and Discord alerting.
- Alloy replaces Promtail; do not add Promtail.
- Prometheus stores only metrics something reads: every scrape job aliases the `keep_used_metrics` keep-list in `apps/prometheus/configmap.yaml`, built from the dashboards, the alert rules, Radar and `scripts/talos-sync.sh`. A new dashboard, alert or exporter whose metric is not listed gets no data and no history, so add the names in the same PR. The edge agent's remote-written series are not filtered. The Prometheus volume is excluded from Longhorn backups.
- Grafana dashboards live in `terraform/grafana/dashboards/<folder>/<name>.json` and are applied over the Grafana HTTP API by the `grafana` Terrakube workspace. They are not ConfigMaps and there is no dashboard sidecar; do not reintroduce either.
- To add a dashboard: drop the JSON in the right folder directory, give it a stable `uid`, strip `id`/`version`/`iteration`, and open a pull request. The plan runs on the PR, the apply runs on merge.
- A new folder directory also needs a title in `var.folders`, or the plan fails on its precondition instead of quietly using General.
- Folders carry `prevent_destroy`. The Kubernetes folder holds the provisioned alert rules from `apps/grafana/alerting.yaml`, and deleting a Grafana folder deletes the rules inside it.
- The Grafana provider authenticates as the admin user over API basic auth, because Grafana cannot provision a service account token declaratively. The password is sealed in `grafana-admin-secret` and mirrored into the workspace's sensitive `grafana_auth` variable. `GF_SECURITY_ADMIN_PASSWORD` only takes effect when the admin user is first created, so rotating it on an existing database also needs `grafana cli admin reset-admin-password` once inside a Grafana pod.
- Avoid alert fatigue. Add alerts only for actionable service availability, high error rate, severe latency, resource exhaustion, data integrity, or security issues.
- Existing cluster alerts already cover basic pod health, restarts, CPU, memory, and disk.

## Cluster Facts

- Platform: Talos Linux, version in `infrastructure/tuppr/talos/talosupgrade.yaml` (Renovate keeps `talos/*.yaml` equal; `just talos-drift` to compare). Nodes are Lenovo ThinkCentre (10T8), legacy BIOS/GRUB, one 256GB SATA SSD shared by etcd and Longhorn (a large Longhorn rebuild can stall etcd; rebuilds run one per node). RAM: lox and tug ~39GiB, t8o 8GiB.
- Base domain: `lab.jackhumes.com`.
- Auth server: `auth.jackhumes.com` externally and `auth.lab.jackhumes.com` internally.
- Flux namespace: `flux-system`. Flux itself is installed and upgraded by Flux Operator (`flux/helm/flux-operator`) from the `FluxInstance` in `infrastructure/flux-instance`; Renovate bumps its `distribution.version`. Do not run `flux install` against the cluster any more, it would fight the operator. Deleting the FluxInstance uninstalls Flux, so it carries `prune: disabled` and its Kustomization is `prune: false`.
- Flux Web UI: `https://flux.lab.jackhumes.com`, served by the operator, OIDC login via Pocket ID (admin group only). Pocket ID groups are impersonated as `pocketid:<group>`; `pocketid:admin` is bound to `flux-web-admin` in `apps/flux-web/rbac.yaml`. Never bind bare Pocket ID group names in RBAC: `admin` is already cluster-admin via `apps/radar/rbac.yaml`.
- Renovate is self-hosted as **Chore Bore** (`apps/chore-bore`): an hourly CronJob running the Renovate CLI as the `Chore Bore` GitHub App (`chore-bore[bot]`), not the Mend-hosted app. Repository rules stay in `renovate.json`; `apps/chore-bore/config.json` holds only global options. Each run mints a one-hour installation token from the App private key sealed in `chore-bore-secrets`; a lost key is regenerated in the App settings and resealed. Dashboard checkboxes act on the next run, or now with `kubectl -n chore-bore create job --from=cronjob/chore-bore chore-bore-manual`; logs are in the Job pod and Loki.
  - Renovate never merges (`"automerge": false`). Minor/patch updates under `apps/` and `terraform/` wait 3 days after release where the registry publishes release dates (ghcr.io does not). Parked apps (`replicas: 0`) are disabled in `renovate.json`; drop their entry when scaling one back up.
- **Jevil** (`apps/jevil`, source in private `member87/jevil`) is the only thing that merges to `main` (see "Merge only with `/jevil merge`"). It also rules on every Chore Bore pull request, labels it (`jevil:pass|review|waiting` plus reason labels), and on its own merges what `apps/jevil/policy.json` passes, one at a time, 08:00-22:00 London, as `jevil-bot[bot]`. Checks in code decide eligibility; Jev (TypeSafe's decision model, via OpenRouter) reads the release notes, Renovate's and the upstream project's (LinuxServer and home-operations images resolve to the application repository; `upstreams` in the policy overrides), and can only send a pull request to review. Each scope (`app`, `terraform`) is `shadow` (label only, you `/jevil merge`) or `merge` in the policy. After every merge it comments with the merge commit, waits for the deploy, and comments again when it is live; an unhealthy deploy gets `jevil:merged-unhealthy`, a revert pull request (merged with `/jevil merge`), and halts every merge but reverts until that label is removed. Commands: `/jevil merge|cancel|reclassify|hold|unhold`. Dashboard: Grafana *Jevil*. Details and the shadow-to-merge criteria: `docs/jevil.md`.
- Sealed Secrets namespace: `sealed-secrets`.
- Every node has an Intel UHD 630 iGPU (i915 extension in the schematic). `infrastructure/intel-gpu-plugin` exposes it as `gpu.intel.com/i915` (4 pods per GPU); request that instead of mounting `/dev/dri` privileged. Immich transcodes with VAAPI and Jellyfin with QSV (set in its `encoding.xml`), both unprivileged.
- Longhorn is the default replicated storage class.
- Direct NFS is used for media/download storage from NAS `10.0.0.9`.
- Use `longhorn` for app config, databases, and monitoring data.
- Use `nfs-manual` or direct NFS PVs only for shared media/download data.
- NAS paths: `/volume1/kubernetes/media`, `/volume1/kubernetes/downloads`, and Longhorn backups at `/volume1/kubernetes/longhorn-backups`.
- Immich off-site backup: `apps/immich-backup` CronJob (04:00) runs `rclone sync` of `library/`, `upload/`, `profile/` and Immich's DB dumps (`backups/` -> `db/`) to B2 bucket `jackhumes-immich-backup`. The sealed key cannot delete; removed files are only hidden and B2 lifecycle rules purge them after 90 days (30 for `db/`). `thumbs/` and `encoded-video/` are skipped. `immich-backup-exporter` (list-only key) lists the bucket every 15 minutes for the *Immich Backup* dashboard (`terraform/grafana/dashboards/media/immich-backup.json`). Restore steps: `docs/immich-backup.md`.
- MetalLB address pool is `10.0.0.200-10.0.0.250`.
- External access uses FRP through the AWS Lightsail edge (`18.171.34.111`); see Public Access & AWS Lightsail Edge (FRP) for the full chain, tunnel map, and SSH steps.
- Public traffic for `auth.jackhumes.com` must route through Traefik so CrowdSec can block banned IPs.
- FRP remote ports: Pocket ID `8081` (via Traefik), Headscale `8082` (direct to `headscale.headscale.svc:8080`), Terrakube webhook gate `8084` (via Traefik).
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
kubectl get talosupgrade,kubernetesupgrade   # tuppr: target vs progress of Talos/Kubernetes upgrades
just talos-drift    # nodes vs the Talos/Kubernetes versions in Git
just talos-sync     # break-glass: upgrade nodes by hand when tuppr cannot
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
### Longhorn Upgrade Stalls: New Instance Manager `OutOfcpu`

- Symptom: after a Longhorn chart upgrade, attached volumes stay on the old engine image (`kubectl -n longhorn-system get engineimages.longhorn.io` refCount never drains), replicas on one node log `invalid instance manager ..., state error`, and the node's new `instance-manager-*` pod is recreated every ~2 minutes with `OutOfcpu` events. Seen on the 1.12.1 -> 1.13.0 upgrade on lox.
- Cause: during an upgrade each node runs the old and the new instance manager side by side, each requesting `guaranteed-instance-manager-cpu` (12% = 714m). The instance-manager pod is bound to its node directly, so kubelet admission rejects it when the node's CPU *requests* are full (lox was at 93%); the scheduler never gets a chance to place it elsewhere.
- Fix: free ~350m of requests on that node. Cordon it and t8o (8GB), delete a few stateless, PVC-less pods (Grafana, the idle Terrakube executor, Flux image-automation/notification controllers) so they land on tug, uncordon once the instance manager is `running`. The engine upgrade then completes on its own within minutes.
- After a live engine upgrade the old instance managers keep running the engine processes (and keep their CPU request) until each volume next detaches; the next node drain (tuppr Talos upgrade) retires them. Check `kubectl describe node` CPU requests before merging a Longhorn upgrade.
- The upgrade's first Helm attempt can also fail with `failed calling webhook "mutator.longhorn.io" ... connection refused` while the managers restart. Upgrades are never rolled back (`upgrade.remediation.retries: 0`); once the managers are Ready, `flux reconcile helmrelease longhorn -n flux-system --force` finishes it.
## Commit Style

Use concise conventional commits:

```text
feat(<scope>): add <thing>
fix(<scope>): resolve <problem>
docs(<scope>): update <topic>
chore(<scope>): perform maintenance
```
