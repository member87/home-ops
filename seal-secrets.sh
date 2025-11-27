#!/usr/bin/env bash

# Sealed Secrets Helper Script
# This script helps you seal secrets for your home-ops Kubernetes cluster

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CONTROLLER_NAMESPACE="sealed-secrets"
CONTROLLER_NAME="sealed-secrets-controller"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if kubeseal is installed
check_kubeseal() {
    if ! command -v kubeseal &> /dev/null; then
        print_error "kubeseal is not installed!"
        echo "Install it with:"
        echo "  Linux: wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/kubeseal-0.24.5-linux-amd64.tar.gz && tar -xvzf kubeseal-0.24.5-linux-amd64.tar.gz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal"
        echo "  macOS: brew install kubeseal"
        exit 1
    fi
    print_info "kubeseal is installed: $(kubeseal --version)"
}

# Check if kubectl is configured
check_kubectl() {
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl is not configured or cluster is not accessible"
        exit 1
    fi
    print_info "kubectl is configured and cluster is accessible"
}

# Check if sealed-secrets controller is running
check_controller() {
    if ! kubectl get pod -n $CONTROLLER_NAMESPACE -l app.kubernetes.io/name=sealed-secrets-controller &> /dev/null; then
        print_warn "Sealed secrets controller is not running in namespace: $CONTROLLER_NAMESPACE"
        print_info "Deploy it with: kubectl apply -f infrastructure/sealed-secrets/"
        return 1
    fi
    print_info "Sealed secrets controller is running"
    return 0
}

# Fetch the public certificate
fetch_cert() {
    print_info "Fetching public certificate from controller..."
    kubeseal --fetch-cert \
        --controller-namespace=$CONTROLLER_NAMESPACE \
        --controller-name=$CONTROLLER_NAME > /tmp/pub-cert.pem
    print_info "Certificate saved to /tmp/pub-cert.pem"
}

# Seal a single value
seal_value() {
    local value="$1"
    local namespace="$2"
    local secret_name="$3"
    local key="$4"
    
    echo -n "$value" | kubeseal --raw \
        --cert=/tmp/pub-cert.pem \
        --from-file=/dev/stdin \
        --namespace "$namespace" \
        --name "$secret_name" \
        --scope strict
}

# Generate random secrets
generate_secret() {
    local type="$1"
    case "$type" in
        hex)
            openssl rand -hex 32
            ;;
        base64)
            openssl rand -base64 32
            ;;
        *)
            print_error "Unknown secret type: $type"
            exit 1
            ;;
    esac
}

# Interactive mode
interactive_mode() {
    print_info "=== Sealed Secrets Interactive Mode ==="
    echo ""
    
    # Select application
    echo "Which application do you want to create sealed secrets for?"
    echo "1) Authelia"
    echo "2) LLDAP"
    echo "3) ArgoCD Repository"
    echo "4) Custom"
    read -p "Enter choice [1-4]: " app_choice
    
    case "$app_choice" in
        1)
            seal_authelia_secrets
            ;;
        2)
            seal_lldap_secrets
            ;;
        3)
            seal_argocd_secrets
            ;;
        4)
            seal_custom_secret
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# Seal Authelia secrets
seal_authelia_secrets() {
    print_info "=== Sealing Authelia Secrets ==="
    
    # Generate secrets
    print_info "Generating random secrets..."
    JWT_SECRET=$(generate_secret hex)
    SESSION_SECRET=$(generate_secret hex)
    STORAGE_KEY=$(generate_secret hex)
    
    print_info "Generated secrets (save these somewhere safe!):"
    echo "  JWT_SECRET: $JWT_SECRET"
    echo "  SESSION_SECRET: $SESSION_SECRET"
    echo "  STORAGE_ENCRYPTION_KEY: $STORAGE_KEY"
    echo ""
    
    # Seal secrets
    print_info "Sealing secrets..."
    SEALED_JWT=$(seal_value "$JWT_SECRET" "authelia" "authelia-secrets" "JWT_SECRET")
    SEALED_SESSION=$(seal_value "$SESSION_SECRET" "authelia" "authelia-secrets" "SESSION_SECRET")
    SEALED_STORAGE=$(seal_value "$STORAGE_KEY" "authelia" "authelia-secrets" "STORAGE_ENCRYPTION_KEY")
    
    # Output
    print_info "Sealed secrets (copy these to apps/authelia/sealedsecret.yaml):"
    echo ""
    echo "  encryptedData:"
    echo "    JWT_SECRET: $SEALED_JWT"
    echo "    SESSION_SECRET: $SEALED_SESSION"
    echo "    STORAGE_ENCRYPTION_KEY: $SEALED_STORAGE"
}

# Seal LLDAP secrets
seal_lldap_secrets() {
    print_info "=== Sealing LLDAP Secrets ==="
    
    # Get password from user
    read -sp "Enter LLDAP admin password: " LLDAP_PASS
    echo ""
    
    # Generate JWT secret
    LLDAP_JWT=$(generate_secret base64)
    print_info "Generated JWT secret: $LLDAP_JWT"
    
    # Seal secrets
    print_info "Sealing secrets..."
    SEALED_PASS=$(seal_value "$LLDAP_PASS" "lldap" "lldap-secrets" "LLDAP_LDAP_USER_PASS")
    SEALED_JWT=$(seal_value "$LLDAP_JWT" "lldap" "lldap-secrets" "LLDAP_JWT_SECRET")
    
    # Output
    print_info "Sealed secrets (copy these to apps/lldap/sealedsecret.yaml):"
    echo ""
    echo "  encryptedData:"
    echo "    LLDAP_LDAP_USER_PASS: $SEALED_PASS"
    echo "    LLDAP_JWT_SECRET: $SEALED_JWT"
}

# Seal ArgoCD secrets
seal_argocd_secrets() {
    print_info "=== Sealing ArgoCD Repository Secrets ==="
    
    read -p "Is this a private repository? (y/n): " is_private
    
    # Seal type and URL
    SEALED_TYPE=$(seal_value "git" "argocd" "home-ops-repo" "type")
    read -p "Enter repository URL: " repo_url
    SEALED_URL=$(seal_value "$repo_url" "argocd" "home-ops-repo" "url")
    
    echo ""
    echo "  encryptedData:"
    echo "    type: $SEALED_TYPE"
    echo "    url: $SEALED_URL"
    
    if [[ "$is_private" == "y" ]]; then
        read -p "Enter GitHub username: " username
        read -sp "Enter GitHub token/password: " password
        echo ""
        
        SEALED_USER=$(seal_value "$username" "argocd" "home-ops-repo" "username")
        SEALED_PASS=$(seal_value "$password" "argocd" "home-ops-repo" "password")
        
        echo "    username: $SEALED_USER"
        echo "    password: $SEALED_PASS"
    fi
}

# Seal custom secret
seal_custom_secret() {
    print_info "=== Sealing Custom Secret ==="
    
    read -p "Enter namespace: " namespace
    read -p "Enter secret name: " secret_name
    read -p "Enter key name: " key_name
    read -sp "Enter value to seal: " value
    echo ""
    
    print_info "Sealing secret..."
    SEALED_VALUE=$(seal_value "$value" "$namespace" "$secret_name" "$key_name")
    
    print_info "Sealed secret:"
    echo "  $key_name: $SEALED_VALUE"
}

# Main script
main() {
    print_info "Sealed Secrets Helper for home-ops"
    echo ""
    
    # Checks
    check_kubeseal
    check_kubectl
    
    if check_controller; then
        fetch_cert
        echo ""
        interactive_mode
    else
        print_error "Cannot proceed without sealed-secrets controller"
        exit 1
    fi
}

# Run main function
main
