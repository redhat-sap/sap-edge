#!/bin/bash

while true; do
    phase=$(oc get csv postgresoperator.v5.5.1 -o json | jq -r '.status.phase')
    if [[ "$phase" == "Succeeded" ]]; then
        echo "CSV status is Succeeded."
        break
    else
        echo "CSV status is still $phase. Waiting..."
        sleep 5  # Adjust the sleep time as needed
    fi
done
