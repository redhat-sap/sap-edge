#!/bin/bash

# Define the name of the PostgreSQL cluster
cluster_name="hippo"

# Loop until readyReplicas equals 1
while true; do
    ready_replicas=$(oc get postgrescluster "$cluster_name" -o json -n sap-eic-external-postgres | jq -r '.status.instances[0].readyReplicas')

    if [[ "$ready_replicas" == "1" ]]; then
        echo "Crunchy Postgres is ready. Exiting loop."
        break
    else
        echo "Crunchy Postgres readyReplicas is $ready_replicas. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
