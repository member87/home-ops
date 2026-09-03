# GitOps Flow

Everything is declared in Git. Nothing is hand-built on servers.

## Cluster side (Flux)

```mermaid
flowchart LR
    DEV["Engineer workstation"] -->|"git push"| REPO["Git repository"]
    REPO -->|"poll 10m"| SC["Flux source-controller<br/>(GitRepository)"]
    SC --> KC["Flux kustomization<br/>(flux-system)"]
    KC --> HR["HelmReleases<br/>(one per app)"]
    HR -->|"renders chart"| CH["App chart wrapper<br/>Chart.yaml + templates/*.yaml"]
    CH -->|"helm upgrade"| K8S["Cluster workloads"]

    SEC["Secrets (plaintext)"] -->|"kubeseal (offline)"| SSEAL["SealedSecret resources"]
    SSEAL --> K8S
    SSC["Sealed-secrets controller"] -.->|"unseal in cluster"| K8S
```

- Each app directory is a minimal chart: plain YAML manifests packaged by a
  glob template. App configuration lives in ConfigMaps; credentials only ever
  exist as SealedSecrets.
- Single-replica stateful apps use `strategy: Recreate` (RWO volumes deadlock
  a RollingUpdate when the replacement schedules on another node).
- Helm upgrade timeouts are raised (15m) so slow first-time image pulls do not
  trip remediation rollbacks.

## Edge VM side (Terraform)

```mermaid
flowchart LR
    TF["terraform/aws-edge"] -->|"tofu apply"| LS["Cloud VPS instance"]
    TF --> FW["Firewall rules<br/>(22, 80, 443 tcp / 3478 udp)"]
    TF --> SIP["Static public IP"]
    TF --> KP["SSH key"]
    LS -->|"user_data launch script"| SVC["docker compose:<br/>tunnel server + TLS + STUN"]
    SVC --> CAP["Egress cap (systemd, 4mbit)"]
    SVC --> SW["1G swapfile"]
```

- The launch script is idempotent and lives in Git: a destroyed/replaced VM
  converges to the same state.
- Secrets (tunnel token) are injected at apply time via environment variables,
  never committed.
- DNS records are the one manual island (managed DNS console).

## Change flow

```mermaid
sequenceDiagram
    participant E as Engineer
    participant G as Git
    participant F as Flux
    participant C as Cluster
    E->>G: commit + push manifests
    G->>F: source fetch (poll/push)
    F->>C: helm upgrade per affected app
    C-->>F: readiness + health checks
    alt upgrade fails
        F->>C: automatic rollback to previous release
    end
```
