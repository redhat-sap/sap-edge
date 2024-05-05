#!/bin/bash

postgres_csv=""

while [ -z "$postgres_csv" ]; do
    redis_csv=$(oc get subscription crunchy-postgres-operator -n sap-eic-external-postgres -o json | jq -r '.status.currentCSV')
    if [ -z "$postgres_csv" ]; then
        echo "No Postgres CSV found. Retrying..."
        sleep 5  # Adjust the sleep time as needed
    fi
done

while true; do
    phase=$(oc get csv $postgres_csv -o json | jq -r '.status.phase')
    if [[ "$phase" == "Succeeded" ]]; then
        echo "Postgres Operator installation is Succeeded."
        break
    else
        echo "Postgres Operator installation is still $phase. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
