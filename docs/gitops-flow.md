# GitOps Flow

Everything is declared in Git. Nothing is hand-built on servers.

## Cluster side (Flux)

```mermaid
flowchart LR
    DEV["Engineer workstation"] -->|"git push"| REPO["Git repository"]
    REPO -->|"poll 10m"| SC["Flux source-controller<br/>(GitRepository)"]
    SC --> KC["Flux root Kustomization<br/>(flux/cluster)"]
    KC --> KS["Kustomization per component<br/>(one per app / infra dir)"]
    KS -->|"server-side apply"| K8S["Cluster workloads"]
    KC --> HR["HelmReleases<br/>(only charts with upstream deps)"]
    HR -->|"helm upgrade on version/values change"| K8S

    SEC["Secrets (plaintext)"] -->|"kubeseal (offline)"| SSEAL["SealedSecret resources"]
    SSEAL --> K8S
    SSC["Sealed-secrets controller"] -.->|"unseal in cluster"| K8S
```

- Each app directory is plain YAML plus a `kustomization.yaml`, applied by its own
  Flux `Kustomization`. A commit therefore only mutates the components whose files
  changed; every other component reconciles as a no-op server-side apply. App
  configuration lives in ConfigMaps; credentials only ever exist as SealedSecrets.
- Only charts with a real upstream dependency stay `HelmRelease`s (`apps/immich`,
  `apps/pihole`, `apps/podinfo`, `charts/cert-manager`, `infrastructure/longhorn`,
  plus `radar` from the skyhook repo). They use `reconcileStrategy: ChartVersion`,
  so they re-render only when `Chart.yaml` `version` or `spec.values` changes -
  an unrelated commit can no longer re-upgrade storage or TLS.
- Single-replica stateful apps use `strategy: Recreate` (RWO volumes deadlock
  a RollingUpdate when the replacement schedules on another node).
- Config that must restart its workload is fed through a kustomize
  `configMapGenerator` (glance, headscale): the name hash changes, so the pods roll.
- There is no automatic rollback for Kustomization-managed components - a bad
  manifest stays applied and is fixed forward. Only the six HelmReleases keep
  Helm's remediation/rollback behaviour.

## Edge VPS side (NixOS + comin)

```mermaid
flowchart LR
    NX["flake.nix + nixos/edge/"] -->|"merge to main"| COMIN["comin on the edge<br/>(polls main, switches)"]
    COMIN --> SYS["NixOS system on OVH VPS"]
    SYS --> FW["NixOS firewall<br/>(80, 443, 7000 tcp / 3478, 41641 udp)"]
    SYS --> SVC["Caddy (TLS) + frps + coturn STUN<br/>+ Tailscale + metrics"]
    SOPS["nixos/edge/secrets.yaml (sops-nix)"] --> SYS
    INST["just edge-install (nixos-anywhere)"] -->|"fresh install"| SYS
```

- comin never reboots; alert `edge-needs-reboot` fires after 6h of
  `comin_need_to_reboot`, and the reboot is done by hand.
- Renovate keeps `flake.lock` current weekly (never automerged); Jevil waits
  for comin to report the merge commit, then runs the edge health checks.
- Secrets are sops-encrypted in `nixos/edge/`, never committed in plaintext.
- DNS records (`terraform/aws-edge-dns`) have no Terrakube workspace; they
  are applied from the workstation through the Cloudflare API.

## Change flow

```mermaid
sequenceDiagram
    participant E as Engineer
    participant G as Git
    participant F as Flux
    participant C as Cluster
    E->>G: commit + push manifests
    G->>F: source fetch (poll/push)
    F->>C: server-side apply for the changed components only
    C-->>F: readiness + health checks
    alt apply or health check fails
        F->>F: retry every 2m, last good state stays applied (fix forward)
    end
```
