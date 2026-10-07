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
NAMESPACE="sap-eic-external-postgres"
SECRET_NAME="edgedb-pguser-edgedb"
PG_CLUSTER_NAME="edgedb"   # shared PostgresCluster backing every EIC instance
ALL=false

# Usage function
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Retrieve PostgreSQL access details from the deployed PostgresCluster.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where PostgreSQL is deployed (default: sap-eic-external-postgres)
    -s, --secret NAME            Connection secret to read (default: edgedb-pguser-edgedb).
                                 For an EIC instance use edgedb-pguser-edgedb-<instance>.
    -a, --all                    Print access details for EVERY database/user on the shared
                                 cluster (one block per EIC instance).
    --cluster NAME               Shared PostgresCluster name used by --all (default: edgedb).
    -h, --help                   Display this help message

EXAMPLES:
    # Get access details for the default database
    $0

    # Get access details for an EIC instance database
    $0 --secret edgedb-pguser-edgedb-eic02

    # List access details for all EIC instances on the shared cluster
    $0 --all

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
        -s|--secret)
            SECRET_NAME="$2"
            shift 2
            ;;
        -a|--all)
            ALL=true
            shift
            ;;
        --cluster)
            PG_CLUSTER_NAME="$2"
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

namespace="$NAMESPACE"

# Print the connection details held in a single pguser secret.
print_db_access() {
    local secret_name="$1"

    if ! $KUBE_CLI get secret "$secret_name" -n "$namespace" &> /dev/null; then
        echo "Error: secret '$secret_name' not found in namespace '$namespace'."
        return 1
    fi

    local dbhostname dbport dbname dbusername dbpassword
    dbhostname=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.host}" | base64 --decode)
    dbport=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.port}" | base64 --decode)
    dbname=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.dbname}" | base64 --decode)
    dbusername=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.user}" | base64 --decode)
    dbpassword=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.password}" | base64 --decode)

    echo "----- Database: ${dbname} (secret: ${secret_name}) -----"
    echo "External DB Hostname: $dbhostname "
    echo "External DB Port: $dbport"
    echo "External DB Name: $dbname"
    echo "External DB Username: $dbusername "
    echo "External DB Password: $dbpassword "
    echo ""
}

if [[ "$ALL" == "true" ]]; then
    # Crunchy labels every per-user connection secret with the cluster name and
    # role=pguser, so this enumerates the default database plus one per EIC instance.
    SELECTOR="postgres-operator.crunchydata.com/cluster=${PG_CLUSTER_NAME},postgres-operator.crunchydata.com/role=pguser"
    SECRETS=$($KUBE_CLI get secret -n "$namespace" -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
    if [[ -z "$SECRETS" ]]; then
        echo "No pguser secrets found for cluster '$PG_CLUSTER_NAME' in namespace '$namespace'."
        exit 1
    fi
    echo "===== PostgreSQL databases on shared cluster '$PG_CLUSTER_NAME' ====="
    echo ""
    while IFS= read -r s; do
        [[ -n "$s" ]] && print_db_access "$s"
    done <<< "$SECRETS"
else
    print_db_access "$SECRET_NAME"
fi

# The TLS root certificate is shared by every database on the cluster.
secret_name="pgo-root-cacert"
output_file="external_postgres_db_tls_root_cert.crt"

# Get the secret and extract the root.crt field
root_crt=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o json | jq -r '.data["root.crt"]' | base64 -d)

# Check if root_crt is not empty
if [[ -n "$root_crt" ]]; then
    # Write the content to the output file
    echo "$root_crt" > "$output_file"
    echo "External DB TLS Root Certificate saved to $output_file"
else
    echo "Error: Failed to fetch root.crt from secret $secret_name in namespace $namespace."
fi
