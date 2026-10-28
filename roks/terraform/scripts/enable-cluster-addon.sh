#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

# Enables a cluster add-on (default version) unless it is already enabled, then
# waits until the add-on leaves the pending/updating state. Other add-ons are
# not touched. Called by the create-time provisioner of
# terraform_data.file_storage_addon (cluster.tf).
#
# Usage: enable-cluster-addon.sh <cluster> <add-on>
# Needs: ibmcloud (already logged in) with the container-service plugin, jq.
# Env:   ADDON_WAIT_SECONDS (default 1200), ADDON_POLL_SECONDS (default 20)

set -euo pipefail

CLUSTER="${1:-}"
ADDON="${2:-}"
WAIT_SECONDS="${ADDON_WAIT_SECONDS:-1200}"
POLL_SECONDS="${ADDON_POLL_SECONDS:-20}"

if [[ -z "${CLUSTER}" || -z "${ADDON}" ]]; then
  echo "Usage: $0 <cluster> <add-on>" >&2
  exit 2
fi

for TOOL in ibmcloud jq; do
  if ! command -v "${TOOL}" >/dev/null 2>&1; then
    echo "Error: ${TOOL} is required (ibmcloud with the container-service plugin, jq)" >&2
    exit 1
  fi
done

# Prints "<version> <health state>" of the add-on, nothing when it is not enabled.
addon_state() {
  ibmcloud ks cluster addon ls --cluster "${CLUSTER}" --output json -q </dev/null |
    jq -r --arg name "${ADDON}" \
      '(. // [])[] | select(.name == $name) | "\(.version // "-") \(.healthState // "")"'
}

if ! STATE=$(addon_state); then
  echo "Error: cannot list the add-ons of cluster ${CLUSTER} (is ibmcloud logged in?)" >&2
  exit 1
fi

if [[ -z "${STATE}" ]]; then
  echo "Enabling add-on ${ADDON} on cluster ${CLUSTER}"
  ibmcloud ks cluster addon enable "${ADDON}" --cluster "${CLUSTER}" -q </dev/null
else
  echo "Add-on ${ADDON} is already enabled on cluster ${CLUSTER} (version ${STATE%% *})"
fi

DEADLINE=$((SECONDS + WAIT_SECONDS))
while :; do
  if ! STATE=$(addon_state); then
    echo "Error: cannot list the add-ons of cluster ${CLUSTER}" >&2
    exit 1
  fi
  VERSION="${STATE%% *}"
  HEALTH="${STATE#* }"
  case "${HEALTH}" in
    normal | available)
      echo "Add-on ${ADDON} ${VERSION} is ready (${HEALTH})"
      exit 0
      ;;
    warning | critical)
      echo "Warning: add-on ${ADDON} ${VERSION} reports health state ${HEALTH}; check: ibmcloud ks cluster addon ls --cluster ${CLUSTER}" >&2
      exit 0
      ;;
  esac
  if ((SECONDS >= DEADLINE)); then
    echo "Error: add-on ${ADDON} still not ready after ${WAIT_SECONDS}s (state: '${STATE}')" >&2
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done
