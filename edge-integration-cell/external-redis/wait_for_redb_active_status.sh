#!/bin/bash

# Define the name of the RedisEnterpriseDatabase
database_name="redb"

# Loop until status equals "active"
while true; do
    status=$(oc get RedisEnterpriseDatabase "$database_name" -o json | jq -r '.status.status')

    if [[ "$status" == "active" ]]; then
        echo "Status is active. Exiting loop."
        break
    else
        echo "Status is $status. Waiting..."
        sleep 10  # Adjust the sleep time as needed
    fi
done
