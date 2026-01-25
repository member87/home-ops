# Home-Ops - Kubernetes Home Lab Infrastructure

A GitOps-managed Kubernetes home lab infrastructure running on Talos Linux, managed with ArgoCD, featuring authentication, monitoring, VPN networking, and media services.

## 🏗️ Architecture Overview

This infrastructure uses a **GitOps** approach where all Kubernetes resources are defined as code in this repository. ArgoCD automatically syncs changes from Git to the cluster, ensuring the actual cluster state matches the desired state defined here.

### Core Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **ArgoCD** | GitOps continuous deployment | `argocd` |
| **Traefik** | Ingress controller & reverse proxy | `traefik` |
| **Authelia** | Single Sign-On (SSO) authentication | `authelia` |
| **Cert-Manager** | Automatic TLS certificate management | `cert-manager` |
| **Sealed Secrets** | Encrypted secrets management | `sealed-secrets` |

### Monitoring Stack

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Prometheus** | Metrics collection and storage | `prometheus` |
| **Grafana** | Visualization and alerting | `grafana` |
| **Loki** | Log aggregation | `loki` |
| **Alloy** | Log shipping (DaemonSet) | `alloy` |
| **kube-state-metrics** | Kubernetes object metrics | `kube-state-metrics` |
| **node-exporter** | Node hardware metrics | `node-exporter` |
| **UnPoller** | UniFi metrics exporter | `unpoller` |

**Access Grafana:** `https://grafana.lab.jackhumes.com`

### VPN & Networking

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Headscale** | Self-hosted Tailscale control plane | `headscale` |
| **Headplane** | Web-based admin UI for Headscale | `headplane` |
| **Tailscale Subnet Router** | Routes LAN traffic to Tailnet | `tailscale-subnet-router` |
| **FRP Client** | Reverse proxy for external access | `frp-client` |
| **MetalLB** | LoadBalancer IP allocation | `metallb-system` |

### Security

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **CrowdSec** | Intrusion Prevention System (IPS) | `crowdsec` |
| **LLDAP** | Lightweight LDAP directory | `lldap` |
| **Pi-hole** | Network-wide ad blocking & DNS | `pihole` |

### Media Services

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Jellyfin** | Media server | `jellyfin` |
| **Prowlarr** | Indexer manager | `prowlarr` |
| **Sonarr** | TV show management | `sonarr` |
| **Radarr** | Movie management | `radarr` |
| **Bazarr** | Subtitle management | `bazarr` |
| **SABnzbd** | Usenet downloader | `sabnzbd` |
| **qBittorrent** | BitTorrent client | `qbittorrent` |
| **Gluetun** | VPN container for routing | `gluetun` |

### Utilities

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Glance** | Dashboard homepage | `glance` |
| **Qui** | QNAP QTS-inspired UI | `qui` |
| **IP Checker** | Public IP monitoring | `ip-checker` |
| **Podinfo** | Testing and debugging app | `podinfo` |

## 🚀 Quick Start

### Prerequisites

- **Kubernetes cluster** running Talos Linux (v1.34+)
- **kubectl** configured to access your cluster
- **kubeseal** for encrypting secrets ([installation guide](https://github.com/bitnami-labs/sealed-secrets#installation))
- **git** for version control

### Initial Setup

1. **Clone the repository:**
   ```bash
   git clone git@github.com:member87/home-ops.git
   cd home-ops
   ```

2. **Bootstrap ArgoCD and infrastructure** (if not already deployed):
   ```bash
   ./bootstrap.sh
   ```

3. **Access ArgoCD UI:**
   ```
   https://argocd.lab.jackhumes.com
   ```

4. **Verify all applications are synced:**
   ```bash
   kubectl get app -n argocd
   ```

## 📁 Repository Structure

```
home-ops/
├── applications/          # ArgoCD Application manifests
│   ├── authelia.yaml     # Application CRD for Authelia
│   ├── grafana.yaml      # Application CRD for Grafana
│   └── ...               # One file per application
├── apps/                  # Kubernetes manifests for each application
│   ├── authelia/
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   ├── sealedsecret.yaml
│   │   ├── ingressroute.yaml
│   │   └── kustomization.yaml
│   ├── grafana/
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── dashboard-*.yaml    # Grafana dashboard ConfigMaps
│   │   └── ...
│   └── ...               # One directory per application
├── infrastructure/        # Core infrastructure components
├── bootstrap/             # Bootstrap configurations
├── bootstrap.sh           # Bootstrap script
├── seal-secrets.sh        # Helper script for sealing secrets
├── renovate.json          # Renovate bot configuration
├── AGENTS.md              # AI agent guidelines
└── README.md              # This file
```

### Key Principles

1. **Each application has its own directory** under `apps/` containing all its Kubernetes resources
2. **ArgoCD Application CRDs** are stored in `applications/` directory
3. **Kustomize is used** for resource management (`kustomization.yaml` in each app directory)
4. **Sealed Secrets** are used for sensitive data (never commit plaintext secrets!)

## 🔒 Secrets Management

### Critical Rules

**⚠️ NEVER commit plaintext secrets to this repository!**

1. **ALWAYS use Sealed Secrets** for sensitive data
2. **Regenerate any secrets** that were accidentally exposed
3. **Image tags** should always be set to a specific version, NEVER `latest`
4. **Glance dashboard** icons and links need updating when adding/removing applications

### What Counts as a Secret?

**ALWAYS seal these values (NEVER put in ConfigMaps):**
- Private keys (RSA, ECDSA, TLS, SSH, OIDC issuer keys)
- HMAC secrets (JWT signing, session secrets)
- Passwords (database, LDAP, service accounts)
- API keys and tokens (GitHub, Discord webhooks, cloud providers)
- OAuth/OIDC client secrets (plaintext, not hashed)
- Encryption keys (database, storage)
- Connection strings with credentials

**Safe to put in ConfigMaps:**
- Hashed passwords (e.g., pbkdf2 hashes for Authelia)
- Public URLs and endpoints
- Feature flags and settings
- Port numbers and hostnames
- Log levels and timeouts

### Using Sealed Secrets

The repository includes a helper script: `seal-secrets.sh`

**Basic usage:**
```bash
# 1. Fetch the sealed secrets certificate
kubeseal --fetch-cert \
  --controller-namespace=sealed-secrets \
  --controller-name=sealed-secrets-controller > /tmp/pub-cert.pem

# 2. Seal a secret value
echo -n 'your-secret-value' | kubeseal --raw \
  --cert=/tmp/pub-cert.pem \
  --from-file=/dev/stdin \
  --namespace <namespace> \
  --name <secret-name> \
  --scope strict
```

**Example sealed secret:**
```yaml
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: app-secret
  namespace: app-namespace
spec:
  encryptedData:
    password: AgB+J1UUzk7vAgubggMGacky...  # Encrypted value
  template:
    metadata:
      name: app-secret
      namespace: app-namespace
    type: Opaque
```

**Generate OIDC client secrets:**
```bash
# Generate random secret
SECRET=$(head -c 32 /dev/urandom | base64)

# Hash for Authelia configuration
kubectl exec -n authelia <pod> -- authelia crypto hash generate pbkdf2 --password "$SECRET"

# Seal plaintext secret for the application
echo -n "$SECRET" | kubeseal --raw \
  --cert=/tmp/pub-cert.pem \
  --from-file=/dev/stdin \
  --namespace <app-namespace> \
  --name <app-secret-name> \
  --scope strict
```

## 🌐 Network Architecture

### Domain Structure

| Domain Pattern | Access Type | Purpose |
|----------------|-------------|---------|
| `*.lab.jackhumes.com` | Internal (Traefik) | Services accessible from LAN/VPN |
| `*.jackhumes.com` | External (via FRP) | Services exposed to public internet |

### External Access via FRP

The cluster uses **FRP (Fast Reverse Proxy)** to expose services to the public internet through an Oracle Cloud VPS.

**Oracle VPS:**
- **IP:** `140.238.67.83`
- **Provider:** Oracle Cloud Infrastructure (Free Tier)
- **FRP Server Port:** 7000

**Network Flow:**
```
Internet → Oracle VPS (140.238.67.83)
           ↓
       Nginx/Caddy (TLS termination)
           ↓
       FRP Server (port 7000)
           ↓
       FRP Client (in k8s cluster)
           ↓
       Traefik (port 80) → CrowdSec Bouncer → Services
```

**Public Endpoints:**
- `auth.jackhumes.com` → Authelia (via Traefik for CrowdSec protection)
- `headscale.jackhumes.com` → Headscale (direct to service)

### IP Addresses

| IP | Service | Notes |
|----|---------|-------|
| `140.238.67.83` | Oracle VPS | FRP server, public endpoints |
| `10.0.0.200` | Traefik | MetalLB LoadBalancer IP |
| `10.0.0.201` | Pi-hole | DNS server |
| `100.64.0.0/10` | Tailnet IPv4 | Headscale-allocated IPs |

## 🔐 Authentication & Authorization

### Authelia (SSO)

Authelia provides Single Sign-On (SSO) for all internal services using OIDC (OpenID Connect).

**Access:** `https://auth.lab.jackhumes.com`

**Backends:**
- **User Directory:** LLDAP (Lightweight LDAP)
- **Session Storage:** SQLite with persistent volume
- **External Access:** `https://auth.jackhumes.com` (via FRP)

### LLDAP

Lightweight LDAP server for user management.

**Access:** `https://lldap.lab.jackhumes.com`

## 📊 Monitoring & Observability

### Grafana Dashboards

Grafana automatically loads dashboards from ConfigMaps with the label `grafana_dashboard: "1"`.

**Dashboard Organization:**
- Kubernetes folder: Cluster-wide metrics
- Security folder: CrowdSec, authentication metrics
- UniFi folder: Network device metrics
- Logs folder: Log analysis dashboards

**Access Grafana:** `https://grafana.lab.jackhumes.com`

### Alerting

Alerts are configured in `apps/grafana/alerting.yaml` and sent to Discord via webhook.

**Alert Severity Levels:**
- `critical` - Immediate action required (service down, data loss risk)
- `warning` - Investigate soon (high resource usage, degraded performance)
- `info` - For awareness only (deployment events)

### CrowdSec Intrusion Prevention

CrowdSec detects and blocks malicious IPs attempting brute-force attacks.

**Features:**
- Parses Authelia logs from Loki
- Detects brute-force attacks using `LePresidente/authelia-bf` scenario
- Bans malicious IPs for 4 hours (default)
- Traefik bouncer middleware blocks banned IPs at the edge

**Verify CrowdSec is working:**
```bash
# Check active bans
kubectl exec -n crowdsec deployment/crowdsec -- cscli decisions list

# Check registered bouncers
kubectl exec -n crowdsec deployment/crowdsec -- cscli bouncers list
```

## 🌍 VPN Networking with Headscale

### Headscale Configuration

Headscale is a self-hosted Tailscale control plane with OIDC authentication via Authelia.

**Access:**
- Internal: `https://headscale.lab.jackhumes.com`
- External: `https://headscale.jackhumes.com`
- Admin UI: `https://headscale.lab.jackhumes.com/admin` (Headplane)

**Key Settings:**
- **IP Allocation:** `100.64.0.0/10` (CGNAT range)
- **DNS:** Magic DNS enabled on `tailnet.lab.jackhumes.com`
- **Nameservers:** Pi-hole (`10.0.0.201`), Cloudflare fallback

### Managing Headscale

**Create pre-auth keys:**
```bash
kubectl exec -it -n headscale deployment/headscale -- \
  headscale preauthkeys create --user default --expiration 24h
```

**List nodes:**
```bash
kubectl exec -it -n headscale deployment/headscale -- \
  headscale nodes list
```

**Enable advertised routes:**
```bash
# List routes
kubectl exec -it -n headscale deployment/headscale -- \
  headscale routes list

# Enable a route
kubectl exec -it -n headscale deployment/headscale -- \
  headscale routes enable -r <route-id>
```

### Tailscale Subnet Router

The subnet router advertises the LAN (`10.0.0.0/24`) to the Tailnet and acts as an exit node.

**After deploying:**
1. Verify the router appears in Headscale nodes
2. Manually enable the advertised routes

## 🛠️ Common Operations

### Deploying a New Application

1. **Create application directory:**
   ```bash
   mkdir -p apps/<app-name>
   ```

2. **Create Kubernetes manifests:**
   - `namespace.yaml` - Namespace definition
   - `deployment.yaml` - Deployment(s)
   - `service.yaml` - Service(s)
   - `configmap.yaml` - Configuration
   - `sealedsecret.yaml` - Sealed secrets (if needed)
   - `ingressroute.yaml` - Ingress (if external access needed)
   - `kustomization.yaml` - Kustomize resource list

3. **Create ArgoCD Application:**
   ```yaml
   # applications/<app-name>.yaml
   ---
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: <app-name>
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/member87/home-ops.git
       targetRevision: HEAD
       path: apps/<app-name>
     destination:
       server: https://kubernetes.default.svc
       namespace: <app-name>
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```

4. **Commit and push:**
   ```bash
   git add applications/<app-name>.yaml apps/<app-name>/
   git commit -m "feat(<app-name>): add <description>"
   git push
   ```

5. **Verify deployment:**
   ```bash
   # Check ArgoCD sync
   kubectl get app -n argocd <app-name>
   
   # Check pods
   kubectl get pods -n <app-name>
   ```

### Updating Configurations

**For ConfigMaps:**
1. Edit the `configmap.yaml` file
2. Commit and push
3. Wait for ArgoCD sync (automatic)
4. Restart pods if config is not hot-reloaded:
   ```bash
   kubectl rollout restart deployment -n <namespace> <deployment>
   ```

**For Secrets:**
1. Generate new secret value
2. Create new sealed secret with `kubeseal`
3. Update `sealedsecret.yaml`
4. Commit and push
5. Pods will get new secret on restart

**For Deployments:**
1. Edit `deployment.yaml`
2. Commit and push
3. ArgoCD automatically rolls out changes

### Viewing Logs

```bash
# View pod logs
kubectl logs -n <namespace> <pod-name>

# Follow logs
kubectl logs -n <namespace> <pod-name> -f

# View previous logs (for crashed pods)
kubectl logs -n <namespace> <pod-name> --previous

# View logs in Grafana with Loki
# Navigate to Grafana → Explore → Select Loki datasource
```

### Debugging Services

```bash
# Check pod status
kubectl get pods -n <namespace>

# Describe pod for events
kubectl describe pod -n <namespace> <pod-name>

# Port forward to test service locally
kubectl port-forward -n <namespace> svc/<service> 8080:80

# Execute commands in pod
kubectl exec -it -n <namespace> <pod-name> -- /bin/sh
```

## 📝 Commit Message Convention

Follow this format for commit messages:

```
<type>(<scope>): <subject>

[optional body]
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation changes
- `refactor` - Code refactoring
- `chore` - Maintenance tasks

**Examples:**
```
feat(monitoring): add Grafana dashboard for CrowdSec metrics

fix(authelia): secure OIDC integration using sealed secrets
- Generate new OIDC client secret and store in sealed secret
- Update Authelia config with hashed client secret
- Remove plaintext secrets from NetBird configmap
```

## 🔧 Troubleshooting

### Application Not Syncing

```bash
# Check application status
kubectl get app -n argocd <app-name>

# View detailed sync status
kubectl describe app -n argocd <app-name>

# Manually trigger sync
kubectl -n argocd patch app <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
```

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n <namespace>

# Describe pod for events
kubectl describe pod -n <namespace> <pod-name>

# Check logs
kubectl logs -n <namespace> <pod-name>
```

**Common issues:**
- **ImagePullBackOff:** Check image name and registry access
- **CrashLoopBackOff:** Check logs for application errors
- **Pending:** Check resource requests and node capacity
- **Secret not found:** Ensure sealed secret was created and unsealed

### Sealed Secret Not Unsealing

```bash
# Check if sealed secret exists
kubectl get sealedsecret -n <namespace>

# Check if controller unsealed it
kubectl get secret -n <namespace>

# Check sealed-secrets controller logs
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets-controller
```

**Common issues:**
- Wrong namespace in sealed secret
- Wrong secret name
- Certificate mismatch (sealed with different cert)

### CrowdSec Not Blocking IPs

```bash
# Verify bouncer is registered
kubectl exec -n crowdsec deployment/crowdsec -- cscli bouncers list

# Check active bans
kubectl exec -n crowdsec deployment/crowdsec -- cscli decisions list

# Check Traefik logs for 403 responses
kubectl logs -n traefik deployment/traefik --tail=100 | grep "403"
```

**Common issues:**
- FRP bypassing Traefik (update FRP to route through Traefik)
- Missing `crowdsec-bouncer` middleware in IngressRoute
- Bouncer not registered with LAPI

## 📚 Additional Resources

- **ArgoCD UI:** `https://argocd.lab.jackhumes.com`
- **Authelia UI:** `https://auth.lab.jackhumes.com`
- **Grafana UI:** `https://grafana.lab.jackhumes.com`
- **Headplane UI:** `https://headscale.lab.jackhumes.com/admin`
- **Glance Dashboard:** `https://glance.lab.jackhumes.com`
- **Repository:** https://github.com/member87/home-ops
- **Sealed Secrets Documentation:** https://github.com/bitnami-labs/sealed-secrets
- **Authelia OIDC Documentation:** https://www.authelia.com/integration/openid-connect/
- **Talos Linux Documentation:** https://www.talos.dev/

## 🤝 Contributing

This is a personal home lab infrastructure, but contributions and suggestions are welcome!

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

This project is provided as-is for educational and personal use. See individual component licenses for their respective terms.

## 🙏 Acknowledgments

Built with open-source tools and inspired by the Kubernetes homelab community.

---

**Note:** This README is automatically generated and maintained. For detailed technical guidelines for AI agents working with this infrastructure, see [AGENTS.md](AGENTS.md).
