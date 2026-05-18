# Home-Ops Agent Guide

Keep this file short. Prefer discovering current details from the repo over storing long runbooks here.

## Repository

- `apps/`: Kubernetes manifests and local Helm chart wrappers per application.
- `flux/system/`: Flux `GitRepository` and root `Kustomization`.
- `flux/apps/helmreleases.yaml`: Flux `HelmRelease` inventory for apps.
- `infrastructure/`: cluster infrastructure charts/manifests such as MetalLB, Traefik, cert-manager, Sealed Secrets, Longhorn, and CoreDNS custom hosts.
- `talos/`: SOPS-encrypted Talos configs.
- `charts/`: shared Helm charts.
- `seal-secrets.sh`: helper for Sealed Secrets.

## Core Rules

- Never commit plaintext secrets.
- Use Sealed Secrets for Kubernetes app secrets.
- Use SOPS with age for Talos configs in `talos/`.
- Pin container images to explicit versions; never use `latest`.
- Update Glance dashboard icons/links when adding or removing apps.
- Read files before editing and make targeted changes.
- Test or validate changes when feasible.
- Flux reconciles from Git; do not manually mutate cluster state unless troubleshooting or explicitly requested.

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
- Most app and infrastructure directories are local Helm chart wrappers: `Chart.yaml` plus `templates/manifests.yaml` packages plain YAML for Flux.

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
- Typical files: `namespace.yaml`, `deployment.yaml`, `service.yaml`, `configmap.yaml`, `sealedsecret.yaml`, `ingressroute.yaml`, `Chart.yaml`, `templates/manifests.yaml`, `kustomization.yaml`.
- Keep `Chart.yaml` minimal and keep `templates/manifests.yaml` aligned with the existing glob wrapper pattern.
- Add or update the app `HelmRelease` in `flux/apps/helmreleases.yaml`.
- Use health checks where supported. Use TCP probes when no HTTP health endpoint exists.
- For OIDC apps, create a Pocket ID client and seal the client secret.
- For non-OIDC apps, add Tiny Auth ForwardAuth middleware.
- Only add Grafana dashboards or app alerts when the app exposes Prometheus metrics or has a real exporter.

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
- External access uses FRP through Oracle VPS `140.238.67.83`.
- Public `auth.jackhumes.com` traffic must route through Traefik so CrowdSec can block banned IPs.
- FRP maps Pocket ID through Traefik on remote port `8081`; Headscale maps directly to `headscale.headscale.svc:8080` on remote port `8082`.
- Headscale public URL is `https://headscale.jackhumes.com`.
- Headscale internal URL is `https://headscale.lab.jackhumes.com`.
- Home Assistant runs Home Assistant, OTBR, and Matter Server together and uses `hostNetwork`; preserve the Thread dataset because losing it requires factory-resetting Thread devices.

Important IPs:

| IP | Purpose |
| --- | --- |
| `140.238.67.83` | Oracle VPS / FRP server |
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

## Commit Style

Use concise conventional commits:

```text
feat(<scope>): add <thing>
fix(<scope>): resolve <problem>
docs(<scope>): update <topic>
chore(<scope>): perform maintenance
```
