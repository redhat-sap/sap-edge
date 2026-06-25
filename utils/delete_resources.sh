#!/bin/bash

# SPDX-FileCopyrightText: 2025 SAP edge team
#
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# Reusable JSON patch to remove metadata finalizers
REMOVE_METADATA_FINALIZERS_PATCH='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Usage: ./delete_resources.sh <project_name>
PROJECT=${1:-}

if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project_name>"
  exit 1
fi

if ! oc get project "$PROJECT" &>/dev/null; then
  echo "Project '$PROJECT' not found; nothing to do."
  exit 0
fi

echo "Initiating deletion of project '$PROJECT'..."
if ! oc delete project "$PROJECT" --wait=false; then
  echo "Warning: Failed to initiate deletion of project '$PROJECT'. It might already be deleting."
fi

echo "Fetching project details for '$PROJECT'..."
PROJECT_JSON=$(oc get project "$PROJECT" -o json)

if ! RESOURCE_LINES=$(echo "$PROJECT_JSON" | jq -r '.status.conditions[]? | select(.message | test("Some resources are remaining:")) | .message'); then
  echo "Warning: Failed to parse resource messages from project status."
  RESOURCE_LINES=""
fi

if ! FINALIZER_LINES=$(echo "$PROJECT_JSON" | jq -r '.status.conditions[]? | select(.message | test("Some content in the namespace has finalizers remaining:")) | .message'); then
  echo "Warning: Failed to parse finalizer messages from project status."
  FINALIZER_LINES=""
fi

ALL_LINES=$(printf "%s\n%s" "$RESOURCE_LINES" "$FINALIZER_LINES")

if [[ -z "$ALL_LINES" ]]; then
  echo "No dangling resources or finalizers found."
else
  echo "Detected remaining resources:"
  echo "$ALL_LINES"
fi

if echo "$ALL_LINES" | grep -qE '\bpersistentvolumeclaims\.'; then
  echo "Removing finalizers from PVCs in '$PROJECT'..."
  # Use process substitution or just simple pipe.
  # Note: pipe creates a subshell, so variables set inside wouldn't persist, but we are just running commands.
  oc get pvc -n "$PROJECT" -o name 2>/dev/null | while read -r PVC; do
    echo "Patching $PVC to remove finalizers..."
    if ! oc patch "$PVC" -n "$PROJECT" --type json -p "$REMOVE_METADATA_FINALIZERS_PATCH"; then
      echo "Warning: Failed to patch $PVC"
    fi
    if ! oc delete "$PVC" -n "$PROJECT" --force --grace-period=0; then
      echo "Warning: Failed to delete $PVC"
    fi
  done
fi

# As a safety net, sweep all namespaced resource types: remove finalizers and attempt force deletion
echo "Sweeping all namespaced resource types in '$PROJECT' to remove finalizers and delete..."
oc api-resources --verbs=list --namespaced -o name | while read -r TYPE; do
  [[ "$TYPE" == packagemanifests* ]] && continue
  oc get "$TYPE" -n "$PROJECT" -o name 2>/dev/null | while read -r RES; do
    echo "Patching $RES to remove finalizers..."
    if ! oc patch "$RES" -n "$PROJECT" --type json -p "$REMOVE_METADATA_FINALIZERS_PATCH" 2>/dev/null; then
       echo "Warning: Failed to patch $RES to remove finalizers"
    fi
  done
done

echo "Cleanup initiated for project: $PROJECT"
