#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks/terraform/scripts/delete-vpe-gateways.sh"
echo "============================================"

SCRIPT="$(pwd)/../../roks/terraform/scripts/delete-vpe-gateways.sh"

# Stub ibmcloud: serves endpoint gateways and security groups from JSON state
# files, logs every call, removes deleted objects from the state (except the
# gateway IDs listed in STUB_STUCK, which never disappear), fails the first
# delete request of each gateway ID listed in STUB_FAIL_ONCE, and refuses to
# delete a security group while an iks- gateway of its VPC still exists.
# Gateways listed as "deleting" are gone from the next list on. A delete call
# that gets data on stdin (it could read the rest of the caller's list) is
# logged as "stdin-consumed".
STUB_BIN=$(tmp_dir)
cat > "${STUB_BIN}/ibmcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${STUB_LOG}"
case "$1 ${2:-}" in
  "target -r") exit 0 ;;
  "is endpoint-gateways")
    cat "${STUB_GATEWAYS}"
    jq 'map(select(.lifecycle_state != "deleting"))' "${STUB_GATEWAYS}" > "${STUB_GATEWAYS}.new"
    mv "${STUB_GATEWAYS}.new" "${STUB_GATEWAYS}"
    ;;
  "is security-groups") cat "${STUB_SGS}" ;;
  "is endpoint-gateway-delete")
    if [[ -n "$(cat)" ]]; then echo "stdin-consumed $*" >> "${STUB_LOG}"; fi
    if grep -qx "$3" "${STUB_FAIL_ONCE}"; then
      grep -vx "$3" "${STUB_FAIL_ONCE}" > "${STUB_FAIL_ONCE}.new" || true
      mv "${STUB_FAIL_ONCE}.new" "${STUB_FAIL_ONCE}"
      echo "FAILED: endpoint gateway $3 cannot be deleted right now" >&2
      exit 1
    fi
    if grep -qx "$3" "${STUB_STUCK}"; then exit 0; fi
    jq --arg id "$3" 'map(select(.id != $id))' "${STUB_GATEWAYS}" > "${STUB_GATEWAYS}.new"
    mv "${STUB_GATEWAYS}.new" "${STUB_GATEWAYS}"
    ;;
  "is security-group-delete")
    if [[ -n "$(cat)" ]]; then echo "stdin-consumed $*" >> "${STUB_LOG}"; fi
    VPC=$(jq -r --arg id "$3" '.[] | select(.id == $id) | .vpc.id' "${STUB_SGS}")
    if jq -e --arg vpc "${VPC}" 'any(.[]; .vpc.id == $vpc and (.name | startswith("iks-")))' "${STUB_GATEWAYS}" >/dev/null; then
      echo "security group $3 is in use" >&2
      exit 1
    fi
    jq --arg id "$3" 'map(select(.id != $id))' "${STUB_SGS}" > "${STUB_SGS}.new"
    mv "${STUB_SGS}.new" "${STUB_SGS}"
    ;;
  *) echo "unexpected ibmcloud call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN}/ibmcloud"

# Fresh state: two iks- gateways in vpc-1 and one already being deleted, one
# iks- gateway in vpc-2, one non-iks gateway in vpc-1; the VPE security groups
# of both VPCs plus another security group in vpc-1.
setup_state() {
  STUB_LOG=$(tmp_file)
  STUB_GATEWAYS=$(tmp_file)
  STUB_SGS=$(tmp_file)
  STUB_STUCK=$(tmp_file)
  STUB_FAIL_ONCE=$(tmp_file)
  cat > "${STUB_GATEWAYS}" <<'EOF'
[
  {"id": "gw-1", "name": "iks-registry", "vpc": {"id": "vpc-1"}, "lifecycle_state": "stable"},
  {"id": "gw-2", "name": "iks-s3", "vpc": {"id": "vpc-1"}, "lifecycle_state": "stable"},
  {"id": "gw-3", "name": "iks-registry", "vpc": {"id": "vpc-2"}, "lifecycle_state": "stable"},
  {"id": "gw-4", "name": "my-own-gateway", "vpc": {"id": "vpc-1"}, "lifecycle_state": "stable"},
  {"id": "gw-5", "name": "iks-api", "vpc": {"id": "vpc-1"}, "lifecycle_state": "deleting"}
]
EOF
  cat > "${STUB_SGS}" <<'EOF'
[
  {"id": "sg-1", "name": "kube-vpegw-vpc-1", "vpc": {"id": "vpc-1"}},
  {"id": "sg-2", "name": "kube-vpegw-vpc-2", "vpc": {"id": "vpc-2"}},
  {"id": "sg-3", "name": "kube-other", "vpc": {"id": "vpc-1"}}
]
EOF
  export STUB_LOG STUB_GATEWAYS STUB_SGS STUB_STUCK STUB_FAIL_ONCE
}

run_script() {
  set +e
  TASK_OUT=$(PATH="${STUB_BIN}:${PATH}" bash "${SCRIPT}" "$@" 2>&1)
  TASK_RC=$?
  set -e
}

# Test case: only_iks_gateways_in_vpc_deleted
echo ""
echo "Test: only_iks_gateways_in_vpc_deleted"
echo "--------------------------------------------"
setup_state
VPE_CLEANUP_WAIT_SECONDS=5 VPE_CLEANUP_POLL_SECONDS=0 run_script vpc-1 eu-de
[[ "${TASK_RC}" -eq 0 ]] || { echo "${TASK_OUT}"; fail "expected exit 0, got ${TASK_RC}"; }

grep -qx "target -r eu-de" "${STUB_LOG}" || fail "region eu-de not targeted"
grep -q "^is endpoint-gateway-delete gw-1 " "${STUB_LOG}" || fail "gw-1 (iks-, vpc-1) not deleted"
grep -q "^is endpoint-gateway-delete gw-2 " "${STUB_LOG}" || fail "gw-2 (iks-, vpc-1) not deleted"
! grep -q "endpoint-gateway-delete gw-3" "${STUB_LOG}" || fail "gw-3 in another VPC was deleted"
! grep -q "endpoint-gateway-delete gw-4" "${STUB_LOG}" || fail "non-iks gateway gw-4 was deleted"
! grep -q "endpoint-gateway-delete gw-5" "${STUB_LOG}" || fail "gw-5, already being deleted, was requested again"
! grep -q "^stdin-consumed" "${STUB_LOG}" || { cat "${STUB_LOG}"; fail "an ibmcloud delete call read the caller's stdin"; }
grep -q "^is security-group-delete sg-1 " "${STUB_LOG}" || fail "kube-vpegw-vpc-1 not deleted"
! grep -q "security-group-delete sg-[23]" "${STUB_LOG}" || fail "another security group was deleted"
[[ "$(jq -r '[.[].id] | join(",")' "${STUB_GATEWAYS}")" == "gw-3,gw-4" ]] || fail "unexpected remaining gateways"

# The security group goes only after the gateways are gone
LAST_GW_DELETE=$(grep -n "endpoint-gateway-delete" "${STUB_LOG}" | tail -1 | cut -d: -f1)
SG_DELETE=$(grep -n "security-group-delete" "${STUB_LOG}" | head -1 | cut -d: -f1)
[[ "${SG_DELETE}" -gt "${LAST_GW_DELETE}" ]] || fail "security group deleted before the gateways"
! grep -q "security group sg-1 is in use" <<< "${TASK_OUT}" || fail "security group delete attempted while in use"

echo "✅ PASS: only_iks_gateways_in_vpc_deleted"

# Test case: stuck_gateway_fails
echo ""
echo "Test: stuck_gateway_fails"
echo "--------------------------------------------"
setup_state
echo "gw-2" > "${STUB_STUCK}"
VPE_CLEANUP_WAIT_SECONDS=1 VPE_CLEANUP_POLL_SECONDS=0 run_script vpc-1 eu-de
[[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "expected a non-zero exit"; }
grep -q "gw-2" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "remaining gateway not reported"; }
! grep -q "security-group-delete" "${STUB_LOG}" || fail "security group deleted while a gateway remains"

echo "✅ PASS: stuck_gateway_fails"

# Test case: failed_delete_request_retried
# The first delete request for gw-1 fails; the next poll requests it again
# and the cleanup completes.
echo ""
echo "Test: failed_delete_request_retried"
echo "--------------------------------------------"
setup_state
echo "gw-1" > "${STUB_FAIL_ONCE}"
VPE_CLEANUP_WAIT_SECONDS=5 VPE_CLEANUP_POLL_SECONDS=0 run_script vpc-1 eu-de
[[ "${TASK_RC}" -eq 0 ]] || { echo "${TASK_OUT}"; fail "expected exit 0, got ${TASK_RC}"; }
[[ "$(grep -c "^is endpoint-gateway-delete gw-1 " "${STUB_LOG}")" -eq 2 ]] || { cat "${STUB_LOG}"; fail "gw-1 not requested again after the failed request"; }
[[ "$(grep -c "^is endpoint-gateway-delete gw-2 " "${STUB_LOG}")" -eq 1 ]] || { cat "${STUB_LOG}"; fail "gw-2 should be requested once"; }
grep -q "Warning: delete request for iks-registry (gw-1) failed" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "failed request not warned about"; }
[[ "$(grep -c "Deleting endpoint gateway iks-registry (gw-1)" <<< "${TASK_OUT}")" -eq 1 ]] || { echo "${TASK_OUT}"; fail "repeated request logged again"; }
[[ "$(jq -r '[.[].id] | join(",")' "${STUB_GATEWAYS}")" == "gw-3,gw-4" ]] || fail "unexpected remaining gateways"
grep -q "^is security-group-delete sg-1 " "${STUB_LOG}" || fail "kube-vpegw-vpc-1 not deleted"

echo "✅ PASS: failed_delete_request_retried"

# Test case: nothing_to_delete
echo ""
echo "Test: nothing_to_delete"
echo "--------------------------------------------"
setup_state
VPE_CLEANUP_WAIT_SECONDS=5 VPE_CLEANUP_POLL_SECONDS=0 run_script vpc-3 eu-de
[[ "${TASK_RC}" -eq 0 ]] || { echo "${TASK_OUT}"; fail "expected exit 0, got ${TASK_RC}"; }
! grep -q "delete" "${STUB_LOG}" || fail "something was deleted in an unrelated VPC"

echo "✅ PASS: nothing_to_delete"

# Test case: usage_error
echo ""
echo "Test: usage_error"
echo "--------------------------------------------"
setup_state
run_script vpc-1
[[ "${TASK_RC}" -ne 0 ]] || fail "missing region accepted"
grep -q "Usage" <<< "${TASK_OUT}" || fail "usage not printed"
[[ ! -s "${STUB_LOG}" ]] || fail "ibmcloud called despite the usage error"

echo "✅ PASS: usage_error"
