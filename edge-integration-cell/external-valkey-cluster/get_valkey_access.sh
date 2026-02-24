#!/bin/bash

# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE="sap-eic-external-valkey-cluster"
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Get Valkey cluster access details for SAP EIC configuration.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where Valkey cluster is deployed (default: sap-eic-external-valkey-cluster)
    -o, --output-dir DIR         Directory to save certificates (default: current directory)
    -h, --help                   Display this help message

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
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if logged in
if ! oc whoami &> /dev/null; then
    echo "Not logged into OpenShift cluster"
    exit 1
fi

# Check if Valkey is deployed
if ! oc get pods -l name=valkey -n "$NAMESPACE" &> /dev/null; then
    echo "Valkey not found in namespace ${NAMESPACE}"
    exit 1
fi

# Use headless service DNS names to match TLS certificate SANs
# The cert is generated for the headless service, so SANs cover:
#   *.valkey-headless.<namespace>.svc.cluster.local
#   valkey-headless.<namespace>.svc.cluster.local
MASTER_HOST="valkey-0.valkey-headless.${NAMESPACE}.svc"
MASTER_HOST_FULL="valkey-0.valkey-headless.${NAMESPACE}.svc.cluster.local"
READ_HOST="valkey-headless.${NAMESPACE}.svc"
READ_HOST_FULL="valkey-headless.${NAMESPACE}.svc.cluster.local"

# TLS port (TLS is always enabled for SAP EIC)
PORT="6380"

# Get password from secret
VALKEY_PASSWORD=""
if oc get secret valkey -n "$NAMESPACE" &> /dev/null; then
    VALKEY_PASSWORD=$(oc get secret valkey -n "$NAMESPACE" -o jsonpath='{.data.database-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

# Export CA certificate
CA_CERT_FILE="${OUTPUT_DIR}/valkey_tls_certificate.pem"
if oc get configmap valkey-service-ca -n "$NAMESPACE" &> /dev/null; then
    oc get configmap valkey-service-ca -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' > "$CA_CERT_FILE"
else
    echo "Service CA ConfigMap not found - TLS certificate cannot be exported"
    exit 1
fi

echo "External Valkey Addresses: ${MASTER_HOST_FULL}:${PORT}"
echo "External Valkey Mode: cluster"
echo "External Valkey Username: [leave me blank]"
echo "External Valkey Password: ${VALKEY_PASSWORD:-"<not found>"}"
echo "External Valkey TLS Certificate content saved to ${CA_CERT_FILE}"
echo "External Valkey Server Name: ${MASTER_HOST_FULL}"
