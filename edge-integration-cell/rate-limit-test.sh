#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# This script tests that an endpoint correctly returns a 429 status
# after being called several times in quick succession.

# --- Argument parsing and validation (similar to the other script) ---
HOST="${HOST:-}"
AUTH_KEY="${AUTH_KEY:-}"
INGRESS_IP="${INGRESS_IP:-}"
ENDPOINT_PATH=""

# Simplified parsing for this specific script's needs in Tekton
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    *) ENDPOINT_PATH="$1"; shift 1 ;;
  esac
done

[[ -z "$HOST" ]] && { echo "❌ --host is required."; exit 1; }
[[ -z "$ENDPOINT_PATH" ]] && { echo "❌ endpoint_path is required."; exit 1; }
[[ -z "$AUTH_KEY" ]] && { echo "❌ AUTH_KEY env var is required."; exit 1; }

CURL_OPTS=()
if [[ -n "$INGRESS_IP" ]]; then
  CURL_OPTS+=("--resolve" "${HOST}:443:${INGRESS_IP}")
fi

# --- Main Test Execution ---
echo "--- Triggering requests to activate rate limit for ${ENDPOINT_PATH} ---"

# Fire 6 requests quickly to ensure the limit (more than 5) is hit.
# These are "warm-up" requests; we don't check their results.
for i in {1..10}; do
    echo "Sending warm-up request #$i..."
    curl --silent --output /dev/null --insecure --request GET \
        -H "Authorization: Basic ${AUTH_KEY}" \
        "${CURL_OPTS[@]}" \
        --url "https://${HOST}${ENDPOINT_PATH}" || true # Allow failure
    sleep 0.1
done

echo "--- Sending final request to check for 429 status ---"

# Create a temporary file to store the response body
RESPONSE_BODY_FILE=$(mktemp)
# Execute the final request and capture the HTTP status code
HTTP_STATUS=$(curl --write-out '%{http_code}' --silent --insecure --request GET \
    -H "Authorization: Basic ${AUTH_KEY}" \
    "${CURL_OPTS[@]}" \
    --url "https://${HOST}${ENDPOINT_PATH}" \
    --output "$RESPONSE_BODY_FILE")

echo "Received Status: $HTTP_STATUS"
echo "Received Body:"
cat "$RESPONSE_BODY_FILE"
echo "" # Newline for cleaner logs

# --- Validation ---
if [[ "$HTTP_STATUS" -ne 429 ]]; then
    echo "❌ FAILED: Expected HTTP status 429, but got '$HTTP_STATUS'."
    exit 1
fi
echo "✅ SUCCESS: Received correct HTTP status 429."

# Check if the response body contains the expected error code
if ! grep -q "surgeProtectionLimitExceeded" "$RESPONSE_BODY_FILE"; then
    echo "❌ FAILED: Response body did not contain 'surgeProtectionLimitExceeded'."
    exit 1
fi
echo "✅ SUCCESS: Response body contains correct error 'surgeProtectionLimitExceeded'."

echo "✅ Rate limit test passed for ${ENDPOINT_PATH}."
exit 0