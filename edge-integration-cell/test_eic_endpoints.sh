#!/bin/bash

# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  echo "Usage: $0 [clustername] [auth_key] [ingress_ip]"
  echo "Example: $0 walldorf c2ItZTAzZ... 192.168.99.35"
  echo "You can also export AUTH_KEY and INGRESS_IP as environment variables."
  exit 0
fi

CLUSTER_NAME="${1:-walldorf}"
AUTH_KEY="${2:-${AUTH_KEY:-}}"
INGRESS_IP="${3:-${INGRESS_IP:-}}"

[[ -z $AUTH_KEY   ]] && { echo "❌ No AUTH_KEY provided";   exit 1; }
[[ -z $INGRESS_IP ]] && { echo "❌ No INGRESS_IP provided"; exit 1; }


HOST="eic.apps.${CLUSTER_NAME}.ocp.vslen"
ENDPOINTS=(/http/test1 /http/testelster /slvredis /httpbinipfilter)
echo "Cluster: $CLUSTER_NAME  •  Host: $HOST"


failures=()
for path in "${ENDPOINTS[@]}"; do
  echo "GET https://${HOST}${path}"
  if ! curl --fail --insecure --show-error \
            -H "Authorization: Basic ${AUTH_KEY}" \
            "https://${HOST}${path}" \
            --dump-header - \
            --resolve "${HOST}:443:${INGRESS_IP}"; then
    failures+=("$path")
  fi
done


if ((${#failures[@]})); then
  echo "❌ Failed endpoints: ${failures[*]}"
  exit 1
fi
echo "✅ All endpoints succeeded"
