#!/bin/bash

redis_csv=""

while [ -z "$redis_csv" ]; do
    redis_csv=$(oc get subscription redis-enterprise-operator-cert -n sap-eic-external-redis -o json | jq -r '.status.currentCSV')
    if [ -z "$redis_csv" ]; then
        echo "No Redis CSV found. Retrying..."
        sleep 5  # Adjust the sleep time as needed
    fi
done

echo "Found CSV: $redis_csv"


while true; do
    phase=$(oc get csv $redis_csv -o json | jq -r '.status.phase')
    if [[ "$phase" == "Succeeded" ]]; then
        echo "Postgres Operator installation is Succeeded."
        break
    else
        echo "Postgres Operator installation is still $phase. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
