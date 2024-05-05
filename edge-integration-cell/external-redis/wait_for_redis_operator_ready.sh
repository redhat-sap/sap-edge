#!/bin/bash

redis_csv=""

while [ -z "$redis_csv" ]; do
    redis_csv=$(oc get subscription redis-enterprise-operator-cert -n sap-eic-external-redis -o json | jq -r '.status.currentCSV')
    if [ -z "$redis_csv" ]; then
        echo "No Redis CSV found. Retrying..."
        sleep 5  # Adjust the sleep time as needed
    fi
done

echo "Found CSV from the subscription status: $redis_csv"

namespace=sap-eic-external-redis

while true; do

    # Get CSVs in the namespace and filter by name containing "redis-enterprise-operator"
    csv_list=$(oc get csv -n "$namespace" --no-headers | grep 'redis-enterprise-operator')

    # Check if any CSVs were found
    if [ -z "$csv_list" ]; then
        echo "No CSVs found in namespace $namespace with 'redis-enterprise-operator' in their name."
    else
        echo "CSVs found in namespace $namespace with 'redis-enterprise-operator' in their name:"
        # Extract and print the CSV names
        while IFS= read -r csv_info; do
            redis_csv=$(echo "$csv_info" | awk '{print $1}')
            echo "Current CSV is $redis_csv"
        done <<< "$csv_list"
    fi
    phase=$(oc get csv $redis_csv -n sap-eic-external-redis -o json | jq -r '.status.phase')
    if [[ "$phase" == "Succeeded" ]]; then
        echo "Redis Operator installation is Succeeded."
        break
    else
        echo "Redis Operator installation is still $phase. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
