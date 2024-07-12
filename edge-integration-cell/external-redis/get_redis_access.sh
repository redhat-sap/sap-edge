#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# Define the namespace, RedisEnterpriseDatabase name, and RedisEnterpriseDatabase secret field
namespace="sap-eic-external-redis"
database_name="redb"
database_secret_field="databaseSecretName"

# Get the RedisEnterpriseDatabase JSON definition and extract the databaseSecretName
secret_name=$(kubectl get RedisEnterpriseDatabase "$database_name" -n $namespace -o json | jq -r ".spec.$database_secret_field")

# Check if the secret name is empty
if [[ -z "$secret_name" ]]; then
    echo "Failed to retrieve $database_secret_field from RedisEnterpriseDatabase $database_name."
    exit 1
fi

# Get the secret and extract the password, port, and service_name
secret_data=$(kubectl get secret "$secret_name" -n "$namespace" -o json)
password=$(echo "$secret_data" | jq -r '.data["password"]' | base64 --decode)
port=$(echo "$secret_data" | jq -r '.data["port"]' | base64 --decode)
service_name=$(echo "$secret_data" | jq -r '.data["service_name"]' | base64 --decode)


service_name_with_ns="${service_name}.${namespace}.svc"

# Check if any of the values are empty
if [[ -z "$password" || -z "$port" || -z "$service_name" ]]; then
    echo "Failed to retrieve password, port, or service_name from secret $secret_name in namespace $namespace."
    exit 1
fi

# Get the proxy certificate content
kubectl exec -n sap-eic-external-redis -it rec-0 -c redis-enterprise-node -- cat /etc/opt/redislabs/proxy_cert.pem > external_redis_tls_certificate.pem

echo "External Redis Addresses: $service_name_with_ns:$port"
echo "External Redis Mode: standalone"
echo "External Redis Username: [leave me blank]"
echo "External Redis Password: $password"
echo "External Redis Sentinel Username: [leave me blank]"
echo "External Redis Sentinel Password: [leave me blank]"
echo "External Redis TLS Certificate content saved to external_redis_tls_certificate.pem"
echo "External Redis Server Name: [leave me blank]"
