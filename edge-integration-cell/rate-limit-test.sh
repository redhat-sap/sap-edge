#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# --- Function to display usage ---
usage() {
  cat <<EOF
Usage: $0 --host <hostname> [OPTIONS] <endpoint_path>

Tests that an endpoint correctly returns a 429 status by racing multiple
parallel requests and exiting on the first success.

Required Arguments:
  <endpoint_path>             The path of the endpoint to test (e.g., /http/test1).

Options:
  -H, --host <hostname>       The full hostname to test.
  -k, --auth-key <key>        The basic authentication key. (Env: AUTH_KEY)
  -i, --ingress-ip <ip>       The Ingress IP for internal resolution mode. (Env: INGRESS_IP)
  -p, --public-dns            Use public DNS for resolution (disables --resolve).
  -t, --timeout <seconds>     How long to wait for a 429 response. Defaults to 20.
EOF
  exit 1
}


# --- Argument Parsing ---
HOST="${HOST:-}"
AUTH_KEY="${AUTH_KEY:-}"
INGRESS_IP="${INGRESS_IP:-}"
USE_PUBLIC_DNS=false
ENDPOINT_PATH=""
TIMEOUT_SECONDS=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) HOST="$2"; shift 2 ;;
    -k|--auth-key) AUTH_KEY="$2"; shift 2 ;;
    -i|--ingress-ip) INGRESS_IP="$2"; shift 2 ;;
    -p|--public-dns) USE_PUBLIC_DNS=true; shift 1 ;;
    -t|--timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "❌ Unknown option: $1" >&2; usage ;;
    *) ENDPOINT_PATH="$1"; shift 1 ;;
  esac
done

# --- Configuration Validation ---
[[ -z "$HOST" ]] && { echo "❌ The --host argument is required." >&2; usage; }
[[ -z "$ENDPOINT_PATH" ]] && { echo "❌ The endpoint_path argument is required." >&2; usage; }
[[ -z "$AUTH_KEY" ]] && { echo "❌ No AUTH_KEY provided." >&2; exit 1; }
if ! $USE_PUBLIC_DNS && [[ -z "$INGRESS_IP" ]]; then
  echo "❌ No INGRESS_IP provided for internal resolution mode." >&2
  exit 1
fi

# --- Create a temporary file to act as a success signal ---
SUCCESS_SIGNAL_FILE=$(mktemp)

# --- Ensure all background jobs and the signal file are cleaned up on exit ---
trap 'rm -f "$SUCCESS_SIGNAL_FILE"; kill $(jobs -p) &>/dev/null' EXIT


# --- Main Execution ---
echo "--------------------------------------------------"
echo "Target Host:    $HOST"
echo "Endpoint Path:  $ENDPOINT_PATH"
echo "Timeout:        $TIMEOUT_SECONDS seconds"

CURL_OPTS=()
if ! $USE_PUBLIC_DNS; then
  CURL_OPTS+=("--resolve" "${HOST}:443:${INGRESS_IP}")
fi
echo "--------------------------------------------------"


# --- Launch all requests in parallel background jobs ---
echo "--- Launching 30 parallel requests to race for a 429 status ---"

for i in {1..30}; do
    # Each request runs in its own subshell in the background
    (
        # This sub-process runs independently
        echo "  -> Launching worker #$i..."
        HTTP_STATUS=$(curl --write-out '%{http_code}' --silent --output /dev/null --insecure --request GET \
            -H "Authorization: Basic ${AUTH_KEY}" \
            "${CURL_OPTS[@]}" \
            --url "https://${HOST}${ENDPOINT_PATH}")

        echo "  -> Worker #$i finished with status: $HTTP_STATUS"

        # If this worker gets the 429, it creates the signal file
        if [[ "$HTTP_STATUS" -eq 429 ]]; then
            echo "  -> ✅ Worker #$i got 429! Creating success signal."
            touch "$SUCCESS_SIGNAL_FILE"
        fi
    ) &
done

# --- Wait for Success or Timeout ---
echo "--- Main script waiting for first 429 response or timeout... ---"
SECONDS=0 # Start a timer
while true; do
    # Check if the signal file has been created by a successful worker
    if [[ -f "$SUCCESS_SIGNAL_FILE" ]]; then
        echo "✅ SUCCESS: Signal file found. Rate limit was triggered correctly."
        exit 0 # Success! The trap will clean up remaining jobs.
    fi

    # Check if we have exceeded the timeout
    if (( SECONDS > TIMEOUT_SECONDS )); then
        echo "❌ FAILED: Timed out after $TIMEOUT_SECONDS seconds. No 429 response was received."
        exit 1 # Failure! The trap will clean up remaining jobs.
    fi

    # Wait a moment before checking again
    sleep 0.5
done