#!/bin/bash

# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE="sap-eic-external-valkey-cluster"
RELEASE_NAME="valkey-cluster"
IMAGESTREAMS_RELEASE_NAME="redhat-valkey-imagestreams"
DRY_RUN=false
FORCE=false

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

Cleanup Valkey cluster deployment from OpenShift.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where Valkey cluster is deployed (default: sap-eic-external-valkey-cluster)
    --dry-run                    Show what would be deleted without executing
    -f, --force                  Skip confirmation prompts
    -h, --help                   Display this help message

EXAMPLES:
    $0
    $0 --namespace my-valkey --force
    $0 --dry-run

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

    log_info "Prerequisites check passed"
}

# Uninstall Valkey cluster helm release
uninstall_valkey() {
    log_info "Uninstalling Valkey cluster release..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would uninstall helm release: ${RELEASE_NAME}"
        return
    fi

    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "^${RELEASE_NAME}\s"; then
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
        log_info "Valkey cluster release uninstalled"
    else
        log_warn "Valkey cluster release not found, skipping"
    fi
}

# Uninstall imagestreams helm release
uninstall_imagestreams() {
    log_info "Uninstalling ImageStreams release..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would uninstall helm release: ${IMAGESTREAMS_RELEASE_NAME}"
        return
    fi

    if helm list -n "$NAMESPACE" 2>/dev/null | grep -q "$IMAGESTREAMS_RELEASE_NAME"; then
        helm uninstall "$IMAGESTREAMS_RELEASE_NAME" -n "$NAMESPACE"
        log_info "ImageStreams release uninstalled"
    else
        log_warn "ImageStreams release not found, skipping"
    fi
}

# Delete PVCs created by the StatefulSet
delete_pvcs() {
    log_info "Deleting PersistentVolumeClaims..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would delete PVCs with label template=valkey-cluster-template"
        return
    fi

    if oc get pvc -l template=valkey-cluster-template -n "$NAMESPACE" &> /dev/null; then
        oc delete pvc -l template=valkey-cluster-template -n "$NAMESPACE" 2>/dev/null || log_warn "No PVCs found with label"
        log_info "PVCs deleted"
    else
        log_warn "No PVCs found, skipping"
    fi
}

# Wait for resources to be deleted
wait_for_cleanup() {
    log_info "Waiting for resources to be cleaned up..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would wait for resources to be cleaned up"
        return
    fi

    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if ! oc get pods -l name=valkey -n "$NAMESPACE" 2>/dev/null | grep -q "valkey"; then
            log_info "All Valkey pods deleted"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    echo ""
    log_warn "Some resources may still be cleaning up"
}

# Delete namespace
delete_namespace() {
    log_info "Deleting namespace ${NAMESPACE}..."

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would delete namespace: ${NAMESPACE}"
        return
    fi

    if oc get namespace "$NAMESPACE" &> /dev/null; then
        oc delete namespace "$NAMESPACE"
        log_info "Namespace ${NAMESPACE} deleted"
    else
        log_warn "Namespace ${NAMESPACE} not found, skipping"
    fi
}

# Main execution
main() {
    echo "========================================"
    echo "  Valkey Cluster Cleanup"
    echo "========================================"
    echo ""
    echo "Configuration:"
    echo "  Namespace:    ${NAMESPACE}"
    echo "  Dry Run:      ${DRY_RUN}"
    echo ""

    if ! $FORCE && ! $DRY_RUN; then
        read -p "This will delete all Valkey cluster resources. Proceed? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cleanup cancelled"
            exit 0
        fi
    fi

    check_prerequisites
    uninstall_valkey
    uninstall_imagestreams
    delete_pvcs
    wait_for_cleanup
    delete_namespace

    echo ""
    log_info "Valkey cluster cleanup completed successfully!"
}

main
