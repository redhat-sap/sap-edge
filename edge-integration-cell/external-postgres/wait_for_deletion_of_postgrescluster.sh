#!/bin/bash

# Define the name of the PostgreSQL cluster
cluster_name="eic"

# Define the namespace
namespace="sap-eic-external-postgres"

# Loop until the PostgreSQL cluster is deleted
while true; do
    # Check if the PostgreSQL cluster still exists
    cluster_exists=$(kubectl get postgrescluster "$cluster_name" -n "$namespace" &>/dev/null; echo $?)

    if [[ "$cluster_exists" != 0 ]]; then
        echo "Postgres Cluster $cluster_name is deleted. Exiting loop."
        break
    else
        echo "Postgres Cluster $cluster_name still exists. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
