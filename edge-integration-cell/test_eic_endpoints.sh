#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# --- Function to display usage ---
usage() {
  cat <<EOF
Usage: $0 --host <hostname> [OPTIONS]

Tests API endpoints for a given host.

The script operates in two modes for host resolution:
1.  INTERNAL (default): Uses an Ingress IP to resolve the host via curl's --resolve.
2.  PUBLIC DNS: Assumes the host is resolvable via standard public DNS.

Required Arguments:
  -H, --host <hostname>       The full hostname to test (e.g., eic.apps.walldorf.ocp.vslen).

Options:
  -k, --auth-key <key>        The basic authentication key. (Env: AUTH_KEY)
  -i, --ingress-ip <ip>       The Ingress IP. Required for internal resolution mode. (Env: INGRESS_IP)
  -p, --public-dns            Use public DNS for resolution (disables --resolve). For external hosts.
  -h, --help                  Show this help message.

Example (Internal Host using --resolve):
  $0 --host "eic.apps.walldorf.ocp.vslen" --auth-key "c2ItZ..." --ingress-ip "192.168.99.35"

Example (External Host using Public DNS):
  $0 --host "my.external.host.com" --auth-key "c2ItZ..." --public-dns
EOF
  exit 1
}

# --- Argument Parsing ---
HOST="${HOST:-}"
AUTH_KEY="${AUTH_KEY:-}"
INGRESS_IP="${INGRESS_IP:-}"
USE_PUBLIC_DNS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) HOST="$2"; shift 2 ;;
    -k|--auth-key) AUTH_KEY="$2"; shift 2 ;;
    -i|--ingress-ip) INGRESS_IP="$2"; shift 2 ;;
    -p|--public-dns) USE_PUBLIC_DNS=true; shift 1 ;;
    -h|--help) usage ;;
    *) echo "❌ Unknown option: $1" >&2; usage ;;
  esac
done

# --- Configuration Validation ---
# The --host argument is now mandatory.
if [[ -z "$HOST" ]]; then
  echo "❌ The --host argument is required." >&2
  usage
fi

[[ -z "$AUTH_KEY" ]] && { echo "❌ No AUTH_KEY provided. Use -k or the AUTH_KEY environment variable." >&2; exit 1; }
if ! $USE_PUBLIC_DNS && [[ -z "$INGRESS_IP" ]]; then
  echo "❌ No INGRESS_IP provided for internal resolution mode. Use -i or set --public-dns for external hosts." >&2
  exit 1
fi

# --- Main Execution ---
ENDPOINTS=(/httpbinipfilter /http/test1 /http/testelster /slvredis)
echo "--------------------------------------------------"
echo "Target Host:  $HOST"

CURL_OPTS=()
if $USE_PUBLIC_DNS; then
  echo "Resolution:   Public DNS (--public-dns)"
else
  echo "Resolution:   Internal via --resolve ($INGRESS_IP)"
  CURL_OPTS+=("--resolve" "${HOST}:443:${INGRESS_IP}")
fi
echo "--------------------------------------------------"


failures=()
for path in "${ENDPOINTS[@]}"; do
  echo "======== Send New Request to https://${HOST}${path} ========"
  if ! curl --fail --insecure --show-error --request GET \
            -H "Authorization: Basic ${AUTH_KEY}" \
            "${CURL_OPTS[@]}" \
            --url "https://${HOST}${path}" \
            --dump-header -; then
    failures+=("$path")
  fi
  sleep 1
done

# --- Final Result ---
if ((${#failures[@]})); then
  echo "❌ Failed endpoints: ${failures[*]}"
  exit 1
fi

echo "✅ All endpoints succeeded"