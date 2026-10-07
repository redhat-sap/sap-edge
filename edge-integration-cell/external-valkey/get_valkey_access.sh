#!/bin/bash

# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE_BASE="sap-eic-external-valkey"
NAMESPACE=""            # resolved after arg parse (see instance derivation)
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Get Valkey access details for SAP EIC configuration.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where Valkey is deployed (default: sap-eic-external-valkey)
    -i, --instance NAME          EIC instance name. Reads from namespace "${NAMESPACE_BASE}-<name>".
                                 Ignored if --namespace is given.
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
        -i|--instance)
            INSTANCE="$2"
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

# Resolve namespace: explicit --namespace always wins; otherwise derive from the
# instance name (one namespace per EIC system) or fall back to the legacy default.
if [[ -z "$NAMESPACE" ]]; then
    if [[ -n "$INSTANCE" ]]; then
        NAMESPACE="${NAMESPACE_BASE}-${INSTANCE}"
    else
        NAMESPACE="$NAMESPACE_BASE"
    fi
fi

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

# Export CA certificate. Keep the legacy filename for the default instance, but
# suffix per-instance so several instances can be exported into one directory.
if [[ -n "$INSTANCE" ]]; then
    CA_CERT_FILE="${OUTPUT_DIR}/valkey_tls_certificate_${INSTANCE}.pem"
elif [[ "$NAMESPACE" != "$NAMESPACE_BASE" ]]; then
    CA_CERT_FILE="${OUTPUT_DIR}/valkey_tls_certificate_${NAMESPACE}.pem"
else
    CA_CERT_FILE="${OUTPUT_DIR}/valkey_tls_certificate.pem"
fi
if oc get configmap valkey-service-ca -n "$NAMESPACE" &> /dev/null; then
    oc get configmap valkey-service-ca -n "$NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' > "$CA_CERT_FILE"
else
    echo "Service CA ConfigMap not found - TLS certificate cannot be exported"
    exit 1
fi

echo "External Valkey Addresses: ${SERVICE_HOST}:${PORT}"
echo "External Valkey Mode: standalone"
echo "External Valkey Username: [leave me blank]"
echo "External Valkey Password: ${VALKEY_PASSWORD:-"<not found>"}"
echo "External Valkey TLS Certificate content saved to ${CA_CERT_FILE}"
echo "External Valkey Server Name: ${SERVICE_HOST_FULL}"
