#!/bin/bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# Define the name of the RedisEnterpriseDatabase
database_name="redb"

# Loop until status equals "active"
while true; do
    status=$(kubectl get RedisEnterpriseDatabase "$database_name" -n sap-eic-external-redis -o json | jq -r '.status.status')

    if [[ "$status" == "active" ]]; then
        echo "Redis Enterprise Database Status is active. Exiting loop."
        break
    else
        echo "Redis Enterprise Database Status is $status. Waiting..."
        sleep 10  # Adjust the sleep time as needed
    fi
done
