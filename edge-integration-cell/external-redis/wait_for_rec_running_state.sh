#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# Define the name of the RedisEnterpriseCluster
cluster_name="rec"

# Define the name of the pod
pod_name="rec-0"

# Loop until state equals "Running" and pod is running
while true; do
    cluster_state=$(kubectl get RedisEnterpriseCluster "$cluster_name" -n sap-eic-external-redis -o json | jq -r '.status.state')
    pod_status=$(kubectl get pod "$pod_name" -n sap-eic-external-redis -o json | jq -r '.status.phase')

    if [[ "$cluster_state" == "Running" || "$pod_status" == "Running" ]]; then
        sleep 30 # Let admission webhook to be ready to work with database creation
        echo "Redis Enterprise Cluster State is Running or Pod $pod_name is running. Exiting loop."
        break
    else
        echo "Redis Enterprise Cluster State is $cluster_state and $pod_name is $pod_status. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done