#!/usr/bin/env bash

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to wait for pods to be ready
wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    
    print_info "Waiting for pods with label $label in namespace $namespace to be ready..."
    if kubectl wait --for=condition=ready pod -l "$label" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        print_success "Pods are ready"
        return 0
    else
        print_warning "Timeout waiting for pods, continuing anyway..."
        return 1
    fi
}

# Header
echo ""
echo "=========================================="
echo "  ArgoCD Bootstrap Script"
echo "  Home Lab GitOps Setup"
echo "=========================================="
echo ""

# Step 1: Check if kubectl is available
print_info "Checking prerequisites..."
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    print_error "Cannot connect to Kubernetes cluster"
    exit 1
fi
print_success "kubectl is configured and cluster is accessible"
echo ""

# Step 2: Create namespace and install ArgoCD
print_info "Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace created"
echo ""

print_info "Installing ArgoCD (this may take a minute)..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
print_success "ArgoCD installation manifest applied"
echo ""

# Step 3: Wait for ArgoCD to be ready
print_info "Waiting for ArgoCD components to be ready (this may take 2-3 minutes)..."
wait_for_pods "argocd" "app.kubernetes.io/name=argocd-server" 300
echo ""

# Step 4: Deploy Sealed Secrets (required for secure secret management)
print_info "Deploying Sealed Secrets controller..."
if [ -d "infrastructure/sealed-secrets" ]; then
    kubectl apply -f infrastructure/sealed-secrets/namespace.yaml
    kubectl apply -f infrastructure/sealed-secrets/crds.yaml
    kubectl apply -f infrastructure/sealed-secrets/install.yaml
    print_success "Sealed Secrets controller deployed"
    
    # Wait for controller to be ready
    wait_for_pods "sealed-secrets" "app.kubernetes.io/name=sealed-secrets-controller" 120
else
    print_warning "infrastructure/sealed-secrets not found, skipping"
fi
echo ""

# Step 5: Apply ArgoCD configurations
print_info "Applying ArgoCD configurations..."

if [ -f "bootstrap/argocd-cm.yaml" ]; then
    kubectl apply -f bootstrap/argocd-cm.yaml
    print_success "Applied argocd-cm.yaml"
else
    print_warning "bootstrap/argocd-cm.yaml not found, skipping"
fi

if [ -f "bootstrap/argocd-config.yaml" ]; then
    kubectl apply -f bootstrap/argocd-config.yaml
    print_success "Applied argocd-config.yaml (repository connection)"
else
    print_warning "bootstrap/argocd-config.yaml not found, skipping"
fi

if [ -f "bootstrap/argocd-repo-sealedsecret.yaml" ]; then
    kubectl apply -f bootstrap/argocd-repo-sealedsecret.yaml
    print_success "Applied argocd-repo-sealedsecret.yaml (sealed repository secret)"
else
    print_warning "bootstrap/argocd-repo-sealedsecret.yaml not found, skipping"
fi

if [ -f "bootstrap/argocd-nodeport.yaml" ]; then
    kubectl apply -f bootstrap/argocd-nodeport.yaml
    print_success "Applied argocd-nodeport.yaml (NodePort service)"
else
    print_warning "bootstrap/argocd-nodeport.yaml not found, skipping"
fi

echo ""

# Step 6: Restart ArgoCD server to pick up configuration changes
print_info "Restarting ArgoCD server to apply configuration changes..."
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=180s
print_success "ArgoCD server restarted"
echo ""

# Step 7: Get initial admin password
print_info "Retrieving ArgoCD admin password..."
sleep 5  # Give it a moment to ensure secret is available

PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

if [ -z "$PASSWORD" ]; then
    print_warning "Could not retrieve password automatically"
    print_info "You can retrieve it later with:"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
else
    echo ""
    echo "=========================================="
    echo -e "${GREEN}ArgoCD Admin Credentials:${NC}"
    echo "=========================================="
    echo "Username: admin"
    echo "Password: $PASSWORD"
    echo "=========================================="
    echo ""
fi

# Step 8: Get node IP and display access URLs
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

if [ -z "$NODE_IP" ]; then
    NODE_IP="<your-node-ip>"
fi

echo "=========================================="
echo -e "${GREEN}Access URLs:${NC}"
echo "=========================================="
echo "ArgoCD UI (HTTP):  http://$NODE_IP:30080"
echo "ArgoCD UI (HTTPS): https://$NODE_IP:30443"
echo ""
echo "After root-app is deployed:"
echo "Podinfo:           http://$NODE_IP:30001"
echo "IP-Checker:        http://$NODE_IP:30002"
echo "=========================================="
echo ""

# Step 9: Deploy root application
print_info "Deploying root application..."
if [ -f "bootstrap/root-app.yaml" ]; then
    kubectl apply -f bootstrap/root-app.yaml
    print_success "Root application deployed"
    echo ""
    print_info "ArgoCD will now automatically sync all applications from the repository"
    print_info "This includes: podinfo, ip-checker"
else
    print_error "bootstrap/root-app.yaml not found!"
    print_info "Please apply it manually when ready:"
    echo "  kubectl apply -f bootstrap/root-app.yaml"
fi

echo ""

# Step 10: Show application status
print_info "Checking application status (waiting 10 seconds for sync to start)..."
sleep 10

echo ""
echo "=========================================="
echo -e "${GREEN}ArgoCD Applications:${NC}"
echo "=========================================="
kubectl get applications -n argocd 2>/dev/null || print_warning "No applications found yet"
echo ""

# Final instructions
echo "=========================================="
echo -e "${GREEN}Bootstrap Complete!${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Access ArgoCD UI at http://$NODE_IP:30080"
echo "2. Login with username 'admin' and the password shown above"
echo "3. Watch your applications sync automatically"
echo ""
echo "Useful commands:"
echo "  kubectl get applications -n argocd           # List all applications"
echo "  kubectl get pods -n podinfo                  # Check podinfo pods"
echo "  kubectl get pods -n ip-checker               # Check ip-checker pods"
echo "  kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server  # ArgoCD logs"
echo ""
print_success "All done! Happy GitOps-ing!"
echo ""
