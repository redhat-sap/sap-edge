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

# Usage function
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Retrieve PostgreSQL access details from the deployed PostgresCluster.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace where PostgreSQL is deployed (default: sap-eic-external-postgres)
    -s, --secret NAME            Connection secret to read (default: edgedb-pguser-edgedb).
                                 For an EIC instance use edgedb-pguser-edgedb-<instance>.
    -h, --help                   Display this help message

EXAMPLES:
    # Get access details for the default database
    $0

    # Get access details for an EIC instance database
    $0 --secret edgedb-pguser-edgedb-eic02

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
secret_name="$SECRET_NAME"

# Get dbhostname from the secret
dbhostname=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.host}" | base64 --decode)

# Output the dbhostname
echo "External DB Hostname: $dbhostname "

# Get dbport from the secret
dbport=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.port}" | base64 --decode)

# Output the dbport
echo "External DB Port: $dbport"


# Get dbname from the secret
dbname=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.dbname}" | base64 --decode)

# Output the dbname
echo "External DB Name: $dbname"

# Get dbusername from the secret
dbusername=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.user}" | base64 --decode)

# Output the dbusername
echo "External DB Username: $dbusername "

# Get dbpassword from the secret
dbpassword=$($KUBE_CLI get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.password}" | base64 --decode)

# Output the dbpassword
echo "External DB Password: $dbpassword "

# Define variables
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
