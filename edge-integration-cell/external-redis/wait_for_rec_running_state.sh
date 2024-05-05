#!/bin/bash

# Define the name of the RedisEnterpriseCluster
cluster_name="rec"

# Loop until state equals "Running"
while true; do
    state=$(oc get RedisEnterpriseCluster "$cluster_name" -n sap-eic-external-redis -o json | jq -r '.status.state')

    if [[ "$state" == "Running" ]]; then
        echo "State is Running. Exiting loop."
        break
    else
        echo "State is $state. Waiting..."
        sleep 10  # Adjust the sleep time as needed
    fi
done
