#!/bin/bash

# Set namespace and secret name
namespace="sap-eic-external-postgres"
secret_name="hippo-pguser-hippo"

# Get dbhostname from the secret
dbhostname=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.host}" | base64 --decode)

# Output the dbhostname
echo " External DB Hostname: $dbhostname "

# Get dbport from the secret
dbport=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.port}" | base64 --decode)

# Output the dbport
echo " External DB Port: $dbport"


# Get dbname from the secret
dbname=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.dbname}" | base64 --decode)

# Output the dbname
echo " External DB Name: $dbname"

# Get dbusername from the secret
dbusername=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.user}" | base64 --decode)

# Output the dbusername
echo " External DB User Name: $dbusername "

# Define variables
secret_name="pgo-root-cacert"
output_file="external_db_tls_root_cert"

# Get the secret and extract the root.crt field
root_crt=$(kubectl get secret "$secret_name" -n "$namespace" -o json | jq -r '.data["root.crt"]' | base64 -d)

# Check if root_crt is not empty
if [[ -n "$root_crt" ]]; then
    # Write the content to the output file
    echo "$root_crt" > "$output_file"
    echo "Content of External DB TLS Root Certificate successfully fetched and saved to $output_file."
else
    echo "Error: Failed to fetch root.crt from secret $secret_name in namespace $namespace."
fi
