#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Determine CLI tool (KUBE_CLI env var or oc)
if [[ -n "${KUBE_CLI:-}" ]] && command -v "${KUBE_CLI}" &> /dev/null; then
    : # KUBE_CLI already set from environment
elif command -v oc &> /dev/null; then
    KUBE_CLI="oc"
elif command -v kubectl &> /dev/null; then
    KUBE_CLI="kubectl"
else
    echo "Error: Neither oc nor kubectl found in PATH"
    exit 1
fi

# Default values
NAMESPACE_BASE="sap-eic-external-redis"
NAMESPACE=""            # resolved after arg parse (see instance derivation)
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
CLUSTER_NAME="rec"      # RedisEnterpriseCluster name
DATABASE_NAME="redb"    # RedisEnterpriseDatabase name
OUTPUT_DIR="."

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Retrieve Redis access details from a deployed RedisEnterpriseCluster/Database.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where Redis is deployed (default: sap-eic-external-redis)
    -i, --instance NAME          EIC instance name. Reads from namespace "${NAMESPACE_BASE}-<name>"
                                 so multiple EIC systems can share one cluster. Ignored if
                                 --namespace is given.
    --rec-name NAME              RedisEnterpriseCluster name (default: rec)
    --redb-name NAME             RedisEnterpriseDatabase name (default: redb)
    -o, --output-dir DIR         Directory to save the TLS certificate (default: current directory)
    -h, --help                   Display this help message

EXAMPLES:
    # Default instance
    $0

    # A specific EIC instance
    $0 --instance eic02
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
        --rec-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --redb-name)
            DATABASE_NAME="$2"
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

namespace="$NAMESPACE"
database_name="$DATABASE_NAME"
database_secret_field="databaseSecretName"

# Get the RedisEnterpriseDatabase JSON definition and extract the databaseSecretName
secret_name=$($KUBE_CLI get RedisEnterpriseDatabase "$database_name" -n "$namespace" -o json | jq -r ".spec.$database_secret_field")

# Check if the secret name is empty
if [[ -z "$secret_name" ]]; then
    echo "Failed to retrieve $database_secret_field from RedisEnterpriseDatabase $database_name."
    exit 1
fi

# Get the secret and extract the password, port, and service_name
secret_data=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o json)
password=$(echo "$secret_data" | jq -r '.data["password"]' | base64 --decode)
port=$(echo "$secret_data" | jq -r '.data["port"]' | base64 --decode)
service_name=$(echo "$secret_data" | jq -r '.data["service_name"]' | base64 --decode)


service_name_with_ns="${service_name}.${namespace}.svc"
redis_server_name="${CLUSTER_NAME}.${namespace}.svc.cluster.local"

# Check if any of the values are empty
if [[ -z "$password" || -z "$port" || -z "$service_name" ]]; then
    echo "Failed to retrieve password, port, or service_name from secret $secret_name in namespace $namespace."
    exit 1
fi

# Certificate filename: keep the legacy name for the default instance, but suffix
# per-instance so pulling several instances into one working directory does not
# clobber a previous instance's certificate.
if [[ -n "$INSTANCE" ]]; then
    cert_file="${OUTPUT_DIR}/external_redis_tls_certificate_${INSTANCE}.pem"
else
    cert_file="${OUTPUT_DIR}/external_redis_tls_certificate.pem"
fi

# Get the proxy certificate content
$KUBE_CLI exec -n "$namespace" -it "${CLUSTER_NAME}-0" -c redis-enterprise-node -- cat /etc/opt/redislabs/proxy_cert.pem > "$cert_file"

echo "External Redis Addresses: $service_name_with_ns:$port"
echo "External Redis Mode: standalone"
echo "External Redis Username: [leave me blank]"
echo "External Redis Password: $password"
echo "External Redis Sentinel Username: [leave me blank]"
echo "External Redis Sentinel Password: [leave me blank]"
echo "External Redis TLS Certificate content saved to $cert_file"
echo "External Redis Server Name: $redis_server_name"
