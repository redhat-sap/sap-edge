#!/bin/bash

postgres_csv=""
namespace="sap-eic-external-postgres"

while [ -z "$postgres_csv" ]; do
    postgres_csv=$(oc get subscription crunchy-postgres-operator -n sap-eic-external-postgres -o json | jq -r '.status.currentCSV')
    if [ -z "$postgres_csv" ]; then
        echo "No Postgres CSV found. Retrying..."
        sleep 5  # Adjust the sleep time as needed
    fi
done

while true; do

    # Get CSVs in the namespace and filter by name containing "postgresoperator"
    csv_list=$(oc get csv -n "$namespace" --no-headers | grep 'postgresoperator')

    # Check if any CSVs were found
    if [ -z "$csv_list" ]; then
        echo "No CSVs found in namespace $namespace with 'postgresoperator' in their name."
    else
        echo "CSVs found in namespace $namespace with 'postgresoperator' in their name:"
        # Extract and print the CSV names
        while IFS= read -r csv_info; do
            postgres_csv=$(echo "$csv_info" | awk '{print $1}')
            echo "Current CSV is $postgres_csv"
        done <<< "$csv_list"
    fi
    phase=$(oc get csv $postgres_csv -n sap-eic-external-postgres -o json | jq -r '.status.phase')
    if [[ "$phase" == "Succeeded" ]]; then
        echo "Postgres Operator installation is Succeeded."
        break
    else
        echo "Postgres Operator installation is still $phase. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
