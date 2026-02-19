#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE="sap-eic-external-valkey"
VALKEY_PASSWORD=""
RELEASE_NAME="valkey"
IMAGESTREAMS_RELEASE_NAME="redhat-valkey-imagestreams"
DRY_RUN=false
FORCE=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${SCRIPT_DIR}/charts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploy Valkey with TLS on OpenShift for SAP EIC.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace for Valkey (default: sap-eic-external-valkey)
    -p, --password PASSWORD      Valkey password (required)
    --dry-run                    Show what would be done without executing
    -f, --force                  Skip confirmation prompts
    -h, --help                   Display this help message

EXAMPLES:
    $0 --password mySecretPassword
    $0 --namespace my-valkey --password mySecretPassword
    $0 --password mySecretPassword --dry-run

NOTE: TLS is always enabled (required by SAP EIC).

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -p|--password)
            VALKEY_PASSWORD="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$VALKEY_PASSWORD" ]]; then
    log_error "Valkey password is required. Use -p or --password to specify."
    exit 1
fi

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v oc &> /dev/null; then
        log_error "oc CLI is not installed or not in PATH"
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed or not in PATH"
        exit 1
    fi

    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster"
        exit 1
    fi

    # Check chart directories exist
    if [[ ! -d "${CHARTS_DIR}/redhat-valkey-imagestreams/src" ]]; then
        log_error "Chart directory not found: ${CHARTS_DIR}/redhat-valkey-imagestreams/src"
        exit 1
    fi

    if [[ ! -d "${CHARTS_DIR}/redhat-valkey-persistent/src" ]]; then
        log_error "Chart directory not found: ${CHARTS_DIR}/redhat-valkey-persistent/src"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

# Create namespace if it doesn't exist
create_namespace() {
    log_info "Creating namespace ${NAMESPACE} if it doesn't exist..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create namespace: ${NAMESPACE}"
        return
    fi

    if oc get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Namespace ${NAMESPACE} already exists"
    else
        oc new-project "$NAMESPACE"
        log_info "Namespace ${NAMESPACE} created"
    fi
}

# Install imagestreams chart
install_imagestreams() {
    log_info "Installing redhat-valkey-imagestreams chart..."

    local helm_cmd="helm install ${IMAGESTREAMS_RELEASE_NAME} ${CHARTS_DIR}/redhat-valkey-imagestreams/src -n ${NAMESPACE}"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would run: ${helm_cmd}"
        return
    fi

    # Check if already installed
    if helm list -n "$NAMESPACE" | grep -q "$IMAGESTREAMS_RELEASE_NAME"; then
        log_info "ImageStreams release already installed, upgrading..."
        helm upgrade "$IMAGESTREAMS_RELEASE_NAME" "${CHARTS_DIR}/redhat-valkey-imagestreams/src" -n "$NAMESPACE"
    else
        eval "$helm_cmd"
    fi

    log_info "ImageStreams chart installed successfully"
}

# Install valkey-persistent chart
install_valkey() {
    log_info "Installing redhat-valkey-persistent chart..."

    local helm_cmd="helm install ${RELEASE_NAME} ${CHARTS_DIR}/redhat-valkey-persistent/src -n ${NAMESPACE} --set valkey_password=${VALKEY_PASSWORD}"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would run: helm install ${RELEASE_NAME} ... --set valkey_password=*** [password hidden]"
        return
    fi

    # Check if already installed
    if helm list -n "$NAMESPACE" | grep -q "^${RELEASE_NAME}\s"; then
        log_info "Valkey release already installed, upgrading..."
        helm upgrade "${RELEASE_NAME}" "${CHARTS_DIR}/redhat-valkey-persistent/src" -n "${NAMESPACE}" --set valkey_password="${VALKEY_PASSWORD}"
    else
        eval "$helm_cmd"
    fi

    log_info "Valkey chart installed successfully"
}

# Wait for Valkey to be ready
wait_for_valkey() {
    log_info "Waiting for Valkey pod to be ready..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would wait for Valkey pod to be ready"
        return
    fi

    local max_attempts=60
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if oc get pods -l name=valkey -n "$NAMESPACE" 2>/dev/null | grep -q "Running"; then
            log_info "Valkey pod is running"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 5
    done

    echo ""
    log_error "Timeout waiting for Valkey pod to be ready"
    exit 1
}

# Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would verify deployment"
        return
    fi

    echo ""
    log_info "Checking pods..."
    oc get pods -l name=valkey -n "$NAMESPACE"

    if [[ "$TLS_ENABLED" == "true" ]]; then
        echo ""
        log_info "Checking TLS secret..."
        oc get secret valkey-tls -n "$NAMESPACE" 2>/dev/null || log_warn "TLS secret not found yet (may take a moment)"

        echo ""
        log_info "Checking Service CA ConfigMap..."
        oc get configmap valkey-service-ca -n "$NAMESPACE" 2>/dev/null || log_warn "Service CA ConfigMap not found yet"
    fi

    echo ""
    log_info "Running helm test..."
    helm test "$RELEASE_NAME" -n "$NAMESPACE" || log_warn "Helm test failed or not available"
}

# Main execution
main() {
    echo "========================================"
    echo "  Valkey Deployment for SAP EIC"
    echo "========================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:    ${NAMESPACE}"
    echo "  TLS:          enabled (required by SAP EIC)"
    echo "  Dry Run:      ${DRY_RUN}"
    echo ""

    if ! $FORCE && ! $DRY_RUN; then
        read -p "Proceed with deployment? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi

    check_prerequisites
    create_namespace
    install_imagestreams
    install_valkey
    wait_for_valkey
    verify_deployment

    echo ""
    log_info "Valkey deployment completed successfully!"
    echo ""
    log_info "To get access details, run:"
    echo "  bash ${SCRIPT_DIR}/get_valkey_access.sh -n ${NAMESPACE}"
}

main
