# AI Agent Guidelines for Home-Ops

This document provides guidelines for AI agents working with the home-ops Kubernetes infrastructure. It covers workflows, naming conventions, tools usage, and cluster structure.

## Table of Contents

- [Repository Structure](#repository-structure)
- [Workflow Guidelines](#workflow-guidelines)
- [Naming Conventions](#naming-conventions)
- [Secrets Management](#secrets-management)
- [CLI Tools](#cli-tools)
- [Cluster Information](#cluster-information)
- [Common Operations](#common-operations)
- [Troubleshooting](#troubleshooting)

## Repository Structure

```
home-ops/
├── applications/          # ArgoCD Application manifests
│   ├── authelia.yaml
│   ├── netbird.yaml
│   └── ...
├── apps/                  # Kubernetes manifests for each application
│   ├── authelia/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── sealedsecret.yaml
│   │   ├── service.yaml
│   │   ├── ingressroute.yaml
│   │   ├── namespace.yaml
│   │   └── kustomization.yaml
│   ├── netbird/
│   └── ...
├── bootstrap/             # Bootstrap configurations
├── seal-secrets.sh        # Helper script for sealing secrets
└── AGENTS.md             # This file
```

### Key Principles

1. **Each application has its own directory** under `apps/` containing all its Kubernetes resources
2. **ArgoCD Application CRDs** are stored in `applications/` directory
3. **Kustomize is used** for resource management (kustomization.yaml in each app directory)
4. **Sealed Secrets** are used for sensitive data (never commit plaintext secrets)

## Workflow Guidelines

### General Workflow

1. **Planning**
   - Use the TodoWrite tool to create a task list for complex operations
   - Break down tasks into manageable steps
   - Update todo status as you progress (in_progress → completed)

2. **Making Changes**
   - Read files before editing them
   - Make targeted changes to specific files
   - Test changes when possible before committing

3. **Committing Changes**
   - Follow the commit message convention (see below)
   - Stage all related files together
   - Commit and push in a single operation when ready

4. **Deployment**
   - ArgoCD automatically syncs changes (automated sync policy enabled)
   - If manual sync needed: `kubectl -n argocd patch app <app-name> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'`
   - Monitor pod status after deployment

### Commit Message Convention

Follow this format for commit messages:

```
<type>(<scope>): <subject>

[optional body]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `chore`: Maintenance tasks

**Examples:**
```
fix(netbird): secure OIDC integration with Authelia using sealed secrets

- Generate new OIDC client secret and store in sealed secret
- Update Authelia config with new hashed client secret
- Remove plaintext secrets from NetBird configmap
```

```
feat(monitoring): add Grafana with Authelia SSO integration
```

## Naming Conventions

### Resource Names

1. **Namespaces**: Use lowercase application name (e.g., `authelia`, `netbird`, `lldap`)
2. **Deployments**: `<app-name>` or `<app-name>-<component>` (e.g., `netbird-management`, `netbird-dashboard`)
3. **Services**: Match deployment names
4. **ConfigMaps**: `<app-name>-config` or `<app-name>-<component>-config`
5. **Secrets**: `<app-name>-secrets` or `<app-name>-<component>-secret`
6. **IngressRoutes**: `<app-name>` or `<app-name>-<protocol>` (e.g., `netbird-http`)

### Domain Structure

- **Base domain**: `lab.jackhumes.com`
- **Application URLs**: `<app>.lab.jackhumes.com`
- **Auth server**: `auth.lab.jackhumes.com`

## Secrets Management

### CRITICAL RULES

1. **NEVER commit plaintext secrets** to the repository
2. **ALWAYS use Sealed Secrets** for sensitive data
3. **Regenerate any secrets** that were accidentally exposed
4. **Image Tags** should always be set to a specific version and NEVER lastest. Always check the latest image when adding new services
5. **Glance dashboard** icons and links will need to be updated when removing/adding new applications

### What Counts as a Secret?

**ALWAYS seal these values - NEVER put them in ConfigMaps:**

| Secret Type | Examples | Why It's Sensitive |
|-------------|----------|-------------------|
| **Private Keys** | RSA keys, ECDSA keys, TLS private keys, SSH keys, OIDC issuer private keys | Can be used to impersonate services, sign tokens, or decrypt traffic |
| **HMAC Secrets** | JWT signing secrets, session secrets, OIDC hmac_secret | Allows forging tokens and session hijacking |
| **Passwords** | Database passwords, LDAP bind passwords, service account passwords | Direct access to systems and data |
| **API Keys/Tokens** | GitHub tokens, Discord webhooks, cloud provider keys | Access to external services |
| **Client Secrets** | OAuth/OIDC client secrets (plaintext, not hashed) | Impersonation of OAuth clients |
| **Encryption Keys** | Database encryption keys, storage encryption keys | Data decryption |
| **Connection Strings** | Database URLs with credentials | Database access |

**Safe to put in ConfigMaps (non-secret configuration):**
- Hashed passwords (e.g., pbkdf2 hashes for Authelia client_secret)
- Public URLs and endpoints
- Feature flags and settings
- Port numbers and hostnames
- Log levels and timeouts

### Authelia-Specific Security

Authelia configuration requires special attention because it handles authentication for all services.

**Secrets that MUST be in SealedSecrets (use _FILE env vars):**

```yaml
# In deployment.yaml environment section:
env:
  - name: AUTHELIA_JWT_SECRET_FILE
    value: /secrets/JWT_SECRET
  - name: AUTHELIA_SESSION_SECRET_FILE
    value: /secrets/SESSION_SECRET
  - name: AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE
    value: /secrets/STORAGE_ENCRYPTION_KEY
  - name: AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE
    value: /secrets/OIDC_HMAC_SECRET
  - name: AUTHELIA_IDENTITY_PROVIDERS_OIDC_ISSUER_PRIVATE_KEY_FILE
    value: /secrets/OIDC_ISSUER_PRIVATE_KEY
  - name: AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE
    value: /secrets/LDAP_PASSWORD
```

**Values that stay in ConfigMap:**
- OIDC client secrets (hashed with pbkdf2, e.g., `$pbkdf2-sha512$...`)
- Domain names and URLs
- Session timeouts and policy settings
- LDAP filter configurations

**Red Flags - If you see these in a ConfigMap, STOP and fix:**
- `-----BEGIN RSA PRIVATE KEY-----` or any PEM-formatted key
- `hmac_secret:` followed by a base64 string
- `password:` followed by plaintext
- Any base64-encoded value that looks like a secret

### Using Sealed Secrets

The repository includes a helper script: `seal-secrets.sh`

#### Basic Usage

```bash
# Fetch the sealed secrets certificate
kubeseal --fetch-cert \
  --controller-namespace=sealed-secrets \
  --controller-name=sealed-secrets-controller > /tmp/pub-cert.pem

# Seal a secret value
echo -n 'secret-value' | kubeseal --raw \
  --cert=/tmp/pub-cert.pem \
  --from-file=/dev/stdin \
  --namespace <namespace> \
  --name <secret-name> \
  --scope strict
```

#### Sealed Secret Structure

```yaml
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: app-secret
  namespace: app-namespace
spec:
  encryptedData:
    key_name: AgB+J1UUzk7vAgubggMGacky...  # Encrypted value
  template:
    metadata:
      name: app-secret
      namespace: app-namespace
    type: Opaque
```

### Common Secret Types

1. **OIDC Client Secrets**
   - Generate: `head -c 32 /dev/urandom | base64`
   - Hash for Authelia: `kubectl exec -n authelia <pod> -- authelia crypto hash generate pbkdf2 --password '<secret>'`
   - Seal the plaintext secret for the application

2. **API Keys and Tokens**
   - Always seal before committing
   - Reference via environment variables in deployments

3. **Passwords**
   - Use strong random passwords
   - Seal immediately after generation

## CLI Tools

### kubectl

Primary tool for interacting with the Kubernetes cluster.

**Common Commands:**
```bash
# Get resources
kubectl get pods -n <namespace>
kubectl get app -n argocd

# View logs
kubectl logs -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name> --tail=50

# Describe resources
kubectl describe pod -n <namespace> <pod-name>

# Execute commands in pods
kubectl exec -n <namespace> <pod-name> -- <command>

# Port forwarding
kubectl port-forward -n <namespace> svc/<service> <local-port>:<remote-port>
```

### kubeseal

Used for sealing secrets.

**Installation Check:**
```bash
which kubeseal && kubeseal --version
```

### git

Version control for infrastructure as code.

**Workflow:**
```bash
# Check status
git status

# View changes
git diff <file>

# Stage changes
git add <files>

# Commit
git commit -m "commit message"

# Push
git push
```

## Cluster Information

### Platform
- **OS**: Talos Linux
- **Kubernetes**: v1.34+
- **Nodes**: `talos-lox-1n1` (and others)
- **CNI**: Likely Calico or Cilium
- **Storage**: local-path provisioner

### Installed Components

1. **ArgoCD** (namespace: `argocd`)
   - GitOps continuous deployment
   - Automated sync enabled for all applications
   - Source repo: https://github.com/member87/home-ops.git

2. **Sealed Secrets** (namespace: `sealed-secrets`)
   - Controller: `sealed-secrets-controller`
   - Used for encrypting secrets at rest

3. **Traefik** (ingress controller)
   - Handles HTTP/HTTPS routing
   - Uses IngressRoute CRDs
   - Let's Encrypt integration for TLS

4. **Cert-Manager**
   - Automatic TLS certificate management
   - ClusterIssuer: `letsencrypt-production`

5. **Monitoring Stack** (Prometheus, Grafana, Loki)
   - **Prometheus** (namespace: `prometheus`) - Metrics collection and storage
   - **Grafana** (namespace: `grafana`) - Visualization and alerting
   - **Loki** (namespace: `loki`) - Log aggregation
   - **Promtail** - Log shipping DaemonSet
   - **kube-state-metrics** - Kubernetes object metrics
   - **node-exporter** - Node hardware metrics
   - **Discord alerting** - Configured with webhook for critical alerts
   - Grafana UI: `https://grafana.lab.jackhumes.com`

6. **Headscale** (namespace: `headscale`)
   - Self-hosted Tailscale control plane
   - Image: `headscale/headscale:v0.27.1`
   - Internal URL: `https://headscale.lab.jackhumes.com`
   - External URL: `https://headscale.jackhumes.com` (via FRP tunnel)
   - OIDC integration with Authelia
   - SQLite database with persistent storage

7. **Headplane** (namespace: `headplane`)
   - Web-based admin UI for Headscale
   - Image: `ghcr.io/tale/headplane:0.6.1`
   - Accessible at: `https://headscale.lab.jackhumes.com/admin`

8. **Tailscale Subnet Router** (namespace: `tailscale-subnet-router`)
   - Advertises `10.0.0.0/24` to Tailnet
   - Acts as exit node for VPN traffic
   - Connects to Headscale control plane

9. **FRP Client** (namespace: `frp-client`)
   - Fast Reverse Proxy for external access
   - Tunnels to Oracle VPS for public endpoints
   - See [External Access Architecture](#external-access-architecture) below

### External Access Architecture

The cluster uses **FRP (Fast Reverse Proxy)** to expose services to the public internet through an Oracle Cloud VPS.

**Oracle VPS Details:**
- **IP Address**: `140.238.67.83`
- **Provider**: Oracle Cloud Infrastructure (Free Tier)
- **Role**: FRP server, reverse proxy for public domains
- **FRP Server Port**: 7000

**Network Flow:**
```
Internet --> Oracle VPS (140.238.67.83)
              |
              +-- Nginx/Caddy (TLS termination)
              |     |
              |     +-- headscale.jackhumes.com --> FRP port 8082
              |     +-- auth.jackhumes.com --> FRP port 8081
              |
              +-- FRP Server (port 7000)
                    |
                    +-- FRP Client (in k8s cluster)
                          |
                          +-- headscale.headscale.svc:8080
                          +-- authelia.authelia.svc:9091
```

**FRP Tunnel Configuration** (apps/frp-client/configmap.yaml):

| Proxy Name | Local Service | Local Port | Remote Port | Public Domain |
|------------|---------------|------------|-------------|---------------|
| authelia | authelia.authelia.svc.cluster.local | 9091 | 8081 | auth.jackhumes.com |
| headscale | headscale.headscale.svc.cluster.local | 8080 | 8082 | headscale.jackhumes.com |

**Domain Structure:**

| Domain Pattern | Access Type | Purpose |
|----------------|-------------|---------|
| `*.lab.jackhumes.com` | Internal (Traefik) | Services accessible from LAN/VPN |
| `*.jackhumes.com` | External (via FRP) | Services exposed to public internet |

**Why Two Domains for Headscale:**
- `headscale.jackhumes.com` - Used by Tailscale clients connecting from anywhere (must be publicly accessible)
- `headscale.lab.jackhumes.com` - Used for admin access, health checks, and internal cluster communication
- OIDC uses `auth.jackhumes.com` because the OIDC flow requires a publicly accessible issuer for clients connecting from outside

### Headscale Configuration Details

**Key Configuration Values** (apps/headscale/configmap.yaml):

```yaml
server_url: https://headscale.jackhumes.com  # External URL for clients
listen_addr: 0.0.0.0:8080

# IP Allocation
prefixes:
  v4: 100.64.0.0/10   # CGNAT range
  v6: fd7a:115c:a1e0::/48
allocation: sequential

# DNS Configuration
dns:
  magic_dns: true
  base_domain: tailnet.lab.jackhumes.com
  nameservers:
    global:
      - 10.0.0.201    # Pi-hole
      - 1.1.1.1       # Cloudflare fallback

# OIDC (Authelia)
oidc:
  issuer: https://auth.jackhumes.com
  client_id: headscale
  client_secret_path: /etc/headscale/secrets/client_secret
```

**Creating Pre-Auth Keys:**
```bash
# Get a shell in the headscale pod
kubectl exec -it -n headscale deployment/headscale -- headscale preauthkeys create --user default --expiration 24h

# List existing keys
kubectl exec -it -n headscale deployment/headscale -- headscale preauthkeys list --user default
```

**Managing Nodes:**
```bash
# List all nodes
kubectl exec -it -n headscale deployment/headscale -- headscale nodes list

# Register a node manually
kubectl exec -it -n headscale deployment/headscale -- headscale nodes register --user default --key nodekey:xxx

# Enable routes advertised by a node
kubectl exec -it -n headscale deployment/headscale -- headscale routes enable -r <route-id>
```

### Tailscale Subnet Router Details

The subnet router allows Tailnet clients to access the local network (`10.0.0.0/24`).

**Configuration** (apps/tailscale-subnet-router/deployment.yaml):

```yaml
env:
  - name: TS_HOSTNAME
    value: "k8s-subnet-router"
  - name: TS_ROUTES
    value: "10.0.0.0/24"
  - name: TS_EXTRA_ARGS
    value: "--login-server=https://headscale.jackhumes.com --advertise-exit-node"
```

**After deploying a new subnet router:**
1. The router will appear in Headscale nodes list
2. Routes must be enabled manually:
   ```bash
   kubectl exec -it -n headscale deployment/headscale -- headscale routes list
   kubectl exec -it -n headscale deployment/headscale -- headscale routes enable -r <route-id>
   ```

### Key IP Addresses

| IP | Service | Notes |
|----|---------|-------|
| `140.238.67.83` | Oracle VPS | FRP server, public endpoints |
| `10.0.0.200` | Traefik | MetalLB LoadBalancer IP |
| `10.0.0.201` | Pi-hole | DNS server |
| `100.64.0.0/10` | Tailnet IPv4 | Headscale-allocated IPs |

### Namespaces

- `argocd` - ArgoCD deployment
- `authelia` - Authentication and SSO provider
- `lldap` - Lightweight LDAP server
- `netbird` - VPN management
- `sealed-secrets` - Sealed secrets controller
- (others as needed per application)

## Common Operations

### Deploying a New Application

1. Create application directory structure:
```bash
mkdir -p apps/<app-name>
cd apps/<app-name>
```

2. Create Kubernetes manifests:
   - `namespace.yaml` - Namespace definition
   - `deployment.yaml` - Deployment(s)
   - `service.yaml` - Service(s)
   - `configmap.yaml` - Configuration
   - `sealedsecret.yaml` - Sealed secrets
   - `ingressroute.yaml` - Ingress (if external access needed)
   - `kustomization.yaml` - Kustomize resource list

3. Create ArgoCD Application:
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

4. Commit and push:
```bash
git add applications/<app-name>.yaml apps/<app-name>/
git commit -m "feat(<app-name>): add <description>"
git push
```

### Setting Up Monitoring for Applications

**IMPORTANT:** Only set up Grafana monitoring if the application exports Prometheus metrics. If the application doesn't support Prometheus metrics, skip this entire section and rely on existing cluster-level monitoring (pod health, restarts, resource usage).

When deploying a new application that supports Prometheus metrics, follow these steps to set up dashboards and alerts.

#### 1. Check for Prometheus Metrics Support

**Before proceeding, verify the application exports Prometheus metrics:**
- Check application documentation for `/metrics` endpoint
- Look for Prometheus exporter availability (e.g., postgres_exporter, redis_exporter)
- Check if metrics port is documented
- Test with port-forward: `kubectl port-forward -n <namespace> pod/<pod> 8080:<metrics-port>` then `curl http://localhost:8080/metrics`

**If the application does NOT export Prometheus metrics:**
- **STOP HERE** - Do not create Grafana dashboards or alerts
- The application will still be monitored via existing cluster monitoring (pod status, restarts, resource usage)
- Existing alerts like "Pod Not Ready" and "Pod Restarting Frequently" will cover basic health

**If the application DOES export Prometheus metrics:**
- Proceed to step 2 to configure scraping and set up monitoring

#### 2. Configure Prometheus Scraping (if metrics available)

**Option A: Pod Annotations (Simple)**

Add annotations to the deployment's pod template:

```yaml
# In deployment.yaml pod template metadata
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
```

Prometheus is configured to auto-discover pods with these annotations.

**Option B: ServiceMonitor (Advanced)**

For more control over scraping configuration:

```yaml
# apps/<app-name>/servicemonitor.yaml
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: <app-name>
  namespace: <app-namespace>
spec:
  selector:
    matchLabels:
      app: <app-name>
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

Add to kustomization.yaml and ensure the service has a `metrics` port defined.

#### 3. Create Grafana Dashboard

Create a dashboard ConfigMap in `apps/grafana/`:

**File:** `apps/grafana/dashboard-<app-name>.yaml`

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-<app-name>
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  <app-name>.json: |
    {
      "title": "<App Display Name>",
      "uid": "<app-name>-dashboard",
      "timezone": "browser",
      "schemaVersion": 38,
      "version": 1,
      "refresh": "30s",
      "panels": [
        {
          "title": "Request Rate",
          "type": "graph",
          "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
          "targets": [
            {
              "expr": "rate(http_requests_total{namespace=\"<app-namespace>\"}[5m])",
              "legendFormat": "{{method}} {{status}}"
            }
          ]
        }
      ]
    }
```

**Common Metrics to Monitor:**
- **Request rate**: `rate(http_requests_total[5m])`
- **Error rate**: `rate(http_requests_total{status=~"5.."}[5m])`
- **Latency (p95)**: `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))`
- **Resource usage**: Available via kube-state-metrics
  - CPU requests: `kube_pod_container_resource_requests{resource="cpu", namespace="<namespace>"}`
  - Memory requests: `kube_pod_container_resource_requests{resource="memory", namespace="<namespace>"}`
- **Custom application metrics**: Database connections, queue size, cache hits, etc.

**Dashboard Panel Types:**
- `stat` - Single value display
- `graph` or `timeseries` - Line charts over time
- `gauge` - Progress indicator (good for percentages)
- `table` - Tabular data
- `logs` - Log viewer (use Loki datasource)

#### 4. Set Up Critical Alerts

If there are critical metrics that require alerting, add rules to `apps/grafana/alerting.yaml`:

```yaml
# In the groups section, add new rules
groups:
  - name: <app-name>
    interval: 1m
    rules:
      - uid: <app-name>-<metric>-high
        title: <App Name> <Metric> High
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: prometheus
            model:
              expr: <prometheus-query> > <threshold>
              refId: A
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              conditions:
                - evaluator:
                    params: [0]
                    type: gt
                  operator:
                    type: and
                  query:
                    params: [A]
                  reducer:
                    params: []
                    type: last
                  type: query
              refId: C
              type: classic_conditions
        for: 5m
        annotations:
          summary: <App Name> <metric> is high
          description: "<App Name> <metric> has been above <threshold> for 5 minutes. Current value: {{ $values.A.Value }}"
        labels:
          severity: warning  # or critical
```

**Common Alert Patterns:**
- **High error rate**: `rate(http_requests_total{status=~"5..",namespace="<namespace>"}[5m]) > 10`
- **Service down**: `up{job="<app-name>"} == 0`
- **High latency**: `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m])) > 1`
- **Queue backed up**: `queue_size{namespace="<namespace>"} > 1000`
- **Connection pool exhausted**: `connection_pool_active / connection_pool_max > 0.9`
- **High memory usage**: `container_memory_usage_bytes{namespace="<namespace>"} / container_spec_memory_limit_bytes > 0.9`

**Alert Severity Levels:**
- `critical` - Immediate action required (service down, data loss risk)
- `warning` - Investigate soon (high resource usage, degraded performance)
- `info` - For awareness only (deployment events, scaling events)

#### 5. Update Grafana Resources

**Add dashboard to kustomization** (`apps/grafana/kustomization.yaml`):

```yaml
resources:
  # ... existing resources
  - dashboard-<app-name>.yaml
```

**Mount dashboard in deployment** (`apps/grafana/deployment.yaml`):

```yaml
spec:
  template:
    spec:
      containers:
        - name: grafana
          volumeMounts:
            # ... existing mounts
            - name: dashboard-<app-name>
              mountPath: /var/lib/grafana/dashboards/<app-name>.json
              subPath: <app-name>.json
      volumes:
        # ... existing volumes
        - name: dashboard-<app-name>
          configMap:
            name: grafana-dashboard-<app-name>
```

#### 6. Commit and Deploy Monitoring

```bash
# Stage monitoring resources
git add apps/grafana/dashboard-<app-name>.yaml \
        apps/grafana/kustomization.yaml \
        apps/grafana/deployment.yaml

# If adding alerts
git add apps/grafana/alerting.yaml

# If adding ServiceMonitor
git add apps/<app-name>/servicemonitor.yaml apps/<app-name>/kustomization.yaml

# Commit
git commit -m "feat(grafana): add monitoring dashboard and alerts for <app-name>"

# Push
git push
```

Grafana automatically reloads dashboards within 1-2 minutes. Check Grafana UI at `https://grafana.lab.jackhumes.com`.

#### 7. Verify Monitoring Setup

**Check Prometheus is scraping the target:**
```bash
# Port forward to Prometheus
kubectl port-forward -n prometheus svc/prometheus 9090:9090

# Check targets: http://localhost:9090/targets
# Or query: http://localhost:9090/graph
```

**Check Grafana loaded the dashboard:**
```bash
# Check Grafana logs for dashboard provisioning
kubectl logs -n grafana deployment/grafana | grep -i dashboard

# Access Grafana UI and navigate to Dashboards
```

**Test alerts (if configured):**
```bash
# Check alert rules are loaded
kubectl logs -n grafana deployment/grafana | grep -i alert

# Verify in Grafana UI: Alerting > Alert rules
```

#### When NOT to Set Up Monitoring

Skip Grafana monitoring configuration if:
- Application doesn't export Prometheus metrics and no exporter exists
- Application is internal-only with no critical SLAs (dev tools, one-off jobs)
- Application already included in existing dashboards (e.g., all pods monitored by Cluster Overview)

**Alternatives for non-Prometheus applications:**
- Still monitor pod health via Kubernetes metrics (covered by existing cluster monitoring)
- Use existing "Pod Not Ready" and "Pod Restarting Frequently" alerts
- Consider log-based monitoring with Loki queries if specific log patterns indicate issues
- Use TCP health checks in deployment for basic service availability

#### When to Add Critical Alerts

If you've set up Grafana monitoring for an application with Prometheus metrics, only create alerts for **critical metrics that require immediate attention**:

**Create alerts for:**
- Service availability (service down, all replicas failing)
- High error rates that indicate service degradation
- Critical resource exhaustion (connection pool full, queue backup)
- Data integrity issues (replication lag, backup failures)
- Security issues (authentication failures spike, rate limit exceeded)

**Do NOT create alerts for:**
- Metrics already covered by existing cluster alerts (CPU, memory, disk, pod restarts)
- Informational metrics that don't require action
- Gradual trends that can be monitored in dashboards
- Non-critical services where downtime is acceptable

#### Monitoring Best Practices

1. **Start simple** - Begin with basic metrics (request rate, error rate, latency)
2. **Add resource metrics** - Always monitor CPU and memory usage
3. **Set meaningful thresholds** - Base alert thresholds on actual usage patterns, not arbitrary numbers
4. **Avoid alert fatigue** - Only alert on actionable issues that require human intervention
5. **Use appropriate severity** - Reserve `critical` for service-impacting issues
6. **Test your alerts** - Verify alerts fire correctly before relying on them
7. **Document dashboards** - Use text panels to explain metrics and add context
8. **Keep dashboards focused** - Create separate dashboards for different purposes (overview vs. debugging)

### Configuring OIDC with Authelia

1. **Add OIDC client to Authelia** (apps/authelia/configmap.yaml):
```yaml
- client_id: '<app-name>'
  client_name: '<App Display Name>'
  client_secret: '<pbkdf2-hashed-secret>'
  public: false
  authorization_policy: 'one_factor'
  redirect_uris:
    - 'https://<app>.lab.jackhumes.com/callback'
  scopes:
    - 'openid'
    - 'email'
    - 'profile'
  response_types:
    - 'code'
  grant_types:
    - 'authorization_code'
  token_endpoint_auth_method: 'client_secret_post'
```

2. **Create sealed secret for application**:
```bash
# Generate secret
SECRET=$(head -c 32 /dev/urandom | base64)

# Hash for Authelia
kubectl exec -n authelia <pod> -- authelia crypto hash generate pbkdf2 --password "$SECRET"
# Copy the hash to Authelia config

# Seal for application
echo -n "$SECRET" | kubeseal --raw \
  --cert=/tmp/pub-cert.pem \
  --from-file=/dev/stdin \
  --namespace <app-namespace> \
  --name <app-secret-name> \
  --scope strict
```

3. **Configure application to use Authelia**:
   - Set OIDC endpoints to point to `https://auth.lab.jackhumes.com`
   - Use sealed secret for client secret
   - Configure redirect URIs to match Authelia config

4. **Restart Authelia** after config changes:
```bash
kubectl rollout restart deployment -n authelia authelia
```

### Updating Configurations

1. **For ConfigMaps**:
   - Edit the configmap.yaml file
   - Commit and push
   - Wait for ArgoCD sync
   - Restart affected pods if config is not hot-reloaded

2. **For Secrets**:
   - Generate new secret value
   - Create new sealed secret
   - Update sealedsecret.yaml
   - Commit and push
   - Pods will automatically get new secret on restart

3. **For Deployments**:
   - Edit deployment.yaml
   - Commit and push
   - ArgoCD will automatically roll out changes

### Health Checks

**For HTTP services:**
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /ready
    port: http
  initialDelaySeconds: 10
  periodSeconds: 5
```

**For TCP services (when no HTTP endpoint available):**
```yaml
livenessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 10
  periodSeconds: 5
```

## Troubleshooting

### Application Not Syncing

1. Check ArgoCD application status:
```bash
kubectl get app -n argocd <app-name>
```

2. View detailed sync status:
```bash
kubectl describe app -n argocd <app-name>
```

3. Manually trigger sync:
```bash
kubectl -n argocd patch app <app-name> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
```

### Pods Not Starting

1. Check pod status:
```bash
kubectl get pods -n <namespace>
```

2. Describe pod for events:
```bash
kubectl describe pod -n <namespace> <pod-name>
```

3. Check logs:
```bash
kubectl logs -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name> --previous  # For crashed pods
```

4. Common issues:
   - **ImagePullBackOff**: Check image name and registry access
   - **CrashLoopBackOff**: Check logs for application errors
   - **Pending**: Check resource requests and node capacity
   - **Secret not found**: Ensure sealed secret was created and unsealed

### Sealed Secret Not Unsealing

1. Check if sealed secret exists:
```bash
kubectl get sealedsecret -n <namespace>
```

2. Check if controller unsealed it:
```bash
kubectl get secret -n <namespace>
```

3. Check sealed-secrets controller logs:
```bash
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets-controller
```

4. Common issues:
   - Wrong namespace in sealed secret
   - Wrong secret name
   - Certificate mismatch (sealed with different cert)

### OIDC Authentication Failing

1. Check Authelia logs for errors:
```bash
kubectl logs -n authelia -l app.kubernetes.io/name=authelia
```

2. Common issues:
   - **Redirect URI mismatch**: Ensure redirect URIs in Authelia match what the application sends
   - **Client secret mismatch**: Verify the hashed secret in Authelia matches the plaintext secret in application
   - **Scopes not supported**: Ensure requested scopes are configured in Authelia
   - **Audience mismatch**: Some apps need specific audience configuration

3. Restart Authelia after config changes:
```bash
kubectl rollout restart deployment -n authelia authelia
```

### Prometheus Not Scraping cAdvisor

**Symptoms**: Container metrics (`container_memory_working_set_bytes`, `container_cpu_*`) are not available in Prometheus, resource monitoring alerts won't work.

**Common Issues on Talos Linux**:

1. **TLS Certificate Validation Errors**:
   - Error: `x509: cannot validate certificate for <IP> because it doesn't contain any IP SANs`
   - Solution: Add `insecure_skip_verify: true` to the `kubernetes-cadvisor` job's `tls_config` in Prometheus ConfigMap
   - This is required because Talos kubelet certificates don't include IP SANs

2. **RBAC Permission Errors**:
   - Error: `server returned HTTP status 403 Forbidden`
   - Solution: Ensure Prometheus ClusterRole includes:
     ```yaml
     resources:
       - nodes/metrics
     nonResourceURLs:
       - /metrics/cadvisor
     ```

3. **Verify cAdvisor is working**:
   ```bash
   # Port forward to Prometheus
   kubectl port-forward -n prometheus svc/prometheus 9090:9090
   
   # Check cAdvisor targets health
   curl -s 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.job == "kubernetes-cadvisor")'
   
   # Verify container metrics are available
   curl -s 'http://localhost:9090/api/v1/query?query=container_memory_working_set_bytes' | jq '.data.result | length'
   ```

4. **Restart Prometheus after config changes**:
   ```bash
   kubectl rollout restart deployment -n prometheus prometheus
   ```

### Ingress Not Working

1. Check IngressRoute:
```bash
kubectl get ingressroute -n <namespace>
kubectl describe ingressroute -n <namespace> <name>
```

2. Check certificate:
```bash
kubectl get certificate -n <namespace>
kubectl describe certificate -n <namespace> <cert-name>
```

3. Test with port-forward to bypass ingress:
```bash
kubectl port-forward -n <namespace> svc/<service> 8080:80
curl http://localhost:8080
```

## Best Practices

1. **Always use TodoWrite for complex tasks** to track progress
2. **Read files before editing** to understand context
3. **Never commit plaintext secrets** - use sealed secrets
4. **Follow naming conventions** for consistency
5. **Test changes locally when possible** (port-forward, logs)
6. **Use proper health checks** (TCP vs HTTP based on service)
7. **Document non-obvious decisions** in commit messages
8. **Restart pods after config changes** when needed
9. **Monitor ArgoCD sync status** after pushing changes
10. **Keep this document updated** as the infrastructure evolves

## Additional Resources

- ArgoCD UI: `https://argocd.lab.jackhumes.com`
- Authelia UI: `https://auth.lab.jackhumes.com`
- Sealed Secrets: https://github.com/bitnami-labs/sealed-secrets
- Authelia OIDC Docs: https://www.authelia.com/integration/openid-connect/
