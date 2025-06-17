#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# --- Function to display usage ---
usage() {
  cat <<EOF
Usage: $0 --host <hostname> [OPTIONS] <endpoint_path>

Tests a single API endpoint for a given host.

Required Arguments:
  <endpoint_path>             The path of the endpoint to test (e.g., /http/test1).

Options:
  -H, --host <hostname>       The full hostname to test.
  -k, --auth-key <key>        The basic authentication key. (Env: AUTH_KEY)
  -i, --ingress-ip <ip>       The Ingress IP for internal resolution mode. (Env: INGRESS_IP)
  -p, --public-dns            Use public DNS for resolution (disables --resolve).
  -h, --help                  Show this help message.
EOF
  exit 1
}

# --- Argument Parsing ---
HOST="${HOST:-}"
AUTH_KEY="${AUTH_KEY:-}"
INGRESS_IP="${INGRESS_IP:-}"
USE_PUBLIC_DNS=false
ENDPOINT_PATH=""

# Parse flags first, then grab the final argument as the endpoint path
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) HOST="$2"; shift 2 ;;
    -k|--auth-key) AUTH_KEY="$2"; shift 2 ;;
    -i|--ingress-ip) INGRESS_IP="$2"; shift 2 ;;
    -p|--public-dns) USE_PUBLIC_DNS=true; shift 1 ;;
    -h|--help) usage ;;
    # If it's not a flag, it must be the endpoint path
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

# --- Main Execution ---
echo "--------------------------------------------------"
echo "Target Host:    $HOST"
echo "Endpoint Path:  $ENDPOINT_PATH"

CURL_OPTS=()
if $USE_PUBLIC_DNS; then
  echo "Resolution:     Public DNS (--public-dns)"
else
  echo "Resolution:     Internal via --resolve ($INGRESS_IP)"
  CURL_OPTS+=("--resolve" "${HOST}:443:${INGRESS_IP}")
fi
echo "--------------------------------------------------"


echo "======== Sending New Request to https://${HOST}${ENDPOINT_PATH} ========"
if curl --fail --insecure --show-error --request GET \
          -H "Authorization: Basic ${AUTH_KEY}" \
          "${CURL_OPTS[@]}" \
          --url "https://${HOST}${ENDPOINT_PATH}"; then
  echo "✅ Endpoint succeeded: ${ENDPOINT_PATH}"
  exit 0
else
  echo "❌ Endpoint failed: ${ENDPOINT_PATH}"
  exit 1
fi