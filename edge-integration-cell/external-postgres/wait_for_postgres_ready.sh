#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# Define the name of the PostgreSQL cluster
cluster_name="eic"

# Loop until readyReplicas equals 1
while true; do
    ready_replicas=$(kubectl get postgrescluster "$cluster_name" -o json -n sap-eic-external-postgres | jq -r '.status.instances[0].readyReplicas')

    if [[ "$ready_replicas" == "1" ]]; then
        echo "Crunchy Postgres is ready. Exiting loop."
        break
    else
        echo "Crunchy Postgres readyReplicas is $ready_replicas. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
