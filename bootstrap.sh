#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

echo ""
echo "=========================================="
echo "  Flux Bootstrap Script"
echo "  Home Lab GitOps Setup"
echo "=========================================="
echo ""

print_info "Checking prerequisites..."
if ! command -v kubectl >/dev/null 2>&1; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

if ! command -v flux >/dev/null 2>&1; then
    print_error "flux CLI is not installed or not in PATH"
    print_info "Install instructions: https://fluxcd.io/flux/installation/"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    print_error "Cannot connect to Kubernetes cluster"
    exit 1
fi
print_success "kubectl and flux are configured"
echo ""

print_info "Installing Flux controllers (idempotent)..."
flux install
print_success "Flux controllers are installed"
echo ""

print_info "Applying Flux source and root kustomization..."
kubectl apply -f flux/system/
print_success "Applied manifests in flux/system/"
echo ""

print_info "Reconciling Flux source and root kustomization..."
flux reconcile source git home-ops -n flux-system
flux reconcile kustomization home-ops -n flux-system --with-source
echo ""

print_info "Current Flux status:"
kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io
kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io
echo ""

print_success "Bootstrap complete"
echo ""
echo "Useful commands:"
echo "  flux get all -A"
echo "  flux reconcile source git home-ops -n flux-system"
echo "  flux reconcile kustomization home-ops -n flux-system --with-source"
echo "  kubectl get helmreleases.helm.toolkit.fluxcd.io -A"
