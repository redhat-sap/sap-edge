#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

# Deletes what ROKS leaves behind in a VPC after its last cluster is gone, so
# that Terraform can delete the subnets and the VPC:
#   - the shared VPC endpoint (VPE) gateways named iks-* (Container Registry,
#     COS, cluster service API, VPC API), which ROKS never deletes;
#   - then the security group kube-vpegw-<vpc_id>.
# Only objects of the given VPC are touched. Called by the destroy-time
# provisioner of terraform_data.vpe_cleanup (cluster.tf).
#
# Usage: delete-vpe-gateways.sh <vpc_id> <region>
# Needs: ibmcloud (already logged in) with the vpc-infrastructure plugin, jq.
# Env:   VPE_CLEANUP_WAIT_SECONDS (default 900), VPE_CLEANUP_POLL_SECONDS (default 15)

set -euo pipefail

VPC_ID="${1:-}"
REGION="${2:-}"
WAIT_SECONDS="${VPE_CLEANUP_WAIT_SECONDS:-900}"
POLL_SECONDS="${VPE_CLEANUP_POLL_SECONDS:-15}"

if [[ -z "${VPC_ID}" || -z "${REGION}" ]]; then
  echo "Usage: $0 <vpc_id> <region>" >&2
  exit 2
fi

for TOOL in ibmcloud jq; do
  if ! command -v "${TOOL}" >/dev/null 2>&1; then
    echo "Error: ${TOOL} is required (ibmcloud with the vpc-infrastructure plugin, jq)" >&2
    exit 1
  fi
done

SG_NAME="kube-vpegw-${VPC_ID}"

# Prints "<id> <name> <lifecycle state>" of every iks-* endpoint gateway in the VPC.
list_gateways() {
  ibmcloud is endpoint-gateways --all-resource-groups --output JSON |
    jq -r --arg vpc "${VPC_ID}" \
      '(. // [])[] | select(.vpc.id == $vpc and (.name | startswith("iks-"))) | "\(.id) \(.name) \(.lifecycle_state // "unknown")"'
}

# Requests the deletion of the listed gateways not already being deleted,
# again on every poll (e.g. after a failed or refused request); only the
# first request per gateway is logged. ibmcloud gets no stdin, so that it
# cannot read the rest of the list.
REQUESTED_IDS=" "
request_gateway_deletion() {
  local ID NAME STATE
  while read -r ID NAME STATE; do
    if [[ -z "${ID}" || "${STATE}" == "deleting" ]]; then
      continue
    fi
    if [[ "${REQUESTED_IDS}" == *" ${ID} "* ]]; then
      ibmcloud is endpoint-gateway-delete "${ID}" --force </dev/null >/dev/null 2>&1 || true
      continue
    fi
    REQUESTED_IDS="${REQUESTED_IDS}${ID} "
    echo "Deleting endpoint gateway ${NAME} (${ID})"
    ibmcloud is endpoint-gateway-delete "${ID}" --force </dev/null >/dev/null ||
      echo "Warning: delete request for ${NAME} (${ID}) failed; retrying while waiting" >&2
  done <<< "$1"
}

# Prints the ID of the security group kube-vpegw-<vpc_id> in the VPC, if any.
list_security_groups() {
  ibmcloud is security-groups --vpc "${VPC_ID}" --all-resource-groups --output JSON |
    jq -r --arg vpc "${VPC_ID}" --arg name "${SG_NAME}" \
      '(. // [])[] | select(.vpc.id == $vpc and .name == $name) | .id'
}

echo "Cleaning up ROKS VPE gateways in VPC ${VPC_ID} (${REGION})"
if ! ibmcloud target -r "${REGION}" >/dev/null; then
  echo "Error: cannot target region ${REGION} (is ibmcloud logged in?)" >&2
  exit 1
fi

if ! GATEWAYS=$(list_gateways); then
  echo "Error: cannot list endpoint gateways" >&2
  exit 1
fi

if [[ -n "${GATEWAYS}" ]]; then
  DEADLINE=$((SECONDS + WAIT_SECONDS))
  while :; do
    request_gateway_deletion "${GATEWAYS}"
    sleep "${POLL_SECONDS}"
    if ! GATEWAYS=$(list_gateways); then
      echo "Error: cannot list endpoint gateways" >&2
      exit 1
    fi
    [[ -z "${GATEWAYS}" ]] && break
    if ((SECONDS >= DEADLINE)); then
      echo "Error: endpoint gateways still present in VPC ${VPC_ID} after ${WAIT_SECONDS}s:" >&2
      echo "${GATEWAYS}" >&2
      exit 1
    fi
  done
  echo "Endpoint gateways deleted"
else
  echo "No iks-* endpoint gateways in VPC ${VPC_ID}"
fi

# The security group can still be in use for a short while after the gateways
# are gone; retry until the same deadline.
DEADLINE=$((SECONDS + WAIT_SECONDS))
while :; do
  if ! SG_IDS=$(list_security_groups); then
    echo "Error: cannot list security groups" >&2
    exit 1
  fi
  if [[ -z "${SG_IDS}" ]]; then
    echo "No security group ${SG_NAME} left in VPC ${VPC_ID}"
    break
  fi
  while read -r ID; do
    echo "Deleting security group ${SG_NAME} (${ID})"
    ibmcloud is security-group-delete "${ID}" --force </dev/null >/dev/null ||
      echo "Warning: delete request for security group ${ID} failed" >&2
  done <<< "${SG_IDS}"
  if ! SG_IDS=$(list_security_groups); then
    echo "Error: cannot list security groups" >&2
    exit 1
  fi
  if [[ -z "${SG_IDS}" ]]; then
    echo "Security group ${SG_NAME} deleted"
    break
  fi
  if ((SECONDS >= DEADLINE)); then
    echo "Error: security group ${SG_NAME} still present in VPC ${VPC_ID} after ${WAIT_SECONDS}s: ${SG_IDS}" >&2
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done
