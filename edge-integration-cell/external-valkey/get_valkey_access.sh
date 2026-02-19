#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE="sap-eic-external-valkey"
OUTPUT_DIR="."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Get Valkey access details for SAP EIC configuration.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where Valkey is deployed (default: sap-eic-external-valkey)
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
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if logged in
if ! oc whoami &> /dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

# Check if Valkey is deployed
if ! oc get pods -l name=valkey -n "$NAMESPACE" &> /dev/null; then
    log_error "Valkey not found in namespace ${NAMESPACE}"
    exit 1
fi

echo ""
echo "========================================"
echo "  Valkey Access Details"
echo "========================================"
echo ""

# Get service hostname
SERVICE_HOST="valkey.${NAMESPACE}.svc"
SERVICE_HOST_FULL="valkey.${NAMESPACE}.svc.cluster.local"

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
    log_error "Service CA ConfigMap not found - TLS certificate cannot be exported"
    exit 1
fi

echo -e "${CYAN}SAP EIC Valkey Configuration:${NC}"
echo "  Datastore Type: Valkey"
echo "  Valkey Address: ${SERVICE_HOST_FULL}:${PORT}"
echo "  Valkey Mode: standalone"
echo "  Valkey Username: [leave blank]"
echo "  Valkey Password: ${VALKEY_PASSWORD:-"<not found>"}"
echo "  Valkey TLS Certificate: ${CA_CERT_FILE}"
echo "  Valkey Server Name: ${SERVICE_HOST_FULL}"

echo ""

echo -e "${CYAN}Test Connection:${NC}"
echo "  valkey-cli -h ${SERVICE_HOST} -p ${PORT} \\"
echo "    --tls --cacert ${CA_CERT_FILE} \\"
echo "    -a '${VALKEY_PASSWORD:-<password>}' ping"
echo ""

echo -e "${CYAN}Mount CA Certificate in Application:${NC}"
cat <<EOF
  volumeMounts:
    - name: service-ca
      mountPath: /etc/ssl/service-ca
      readOnly: true
  volumes:
    - name: service-ca
      configMap:
        name: valkey-service-ca
EOF

echo ""
log_info "Access details retrieved successfully"
