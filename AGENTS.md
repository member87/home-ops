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
