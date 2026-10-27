#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

PREPARE_YAML=../../.tekton/tasks/ossm3-prepare-namespaces-task.yaml
MESH_YAML=../../.tekton/tasks/ossm3-configure-mesh-task.yaml
ALL_NAMESPACES="edgelm istio-gateways edge-icell edge-icell-secrets edge-icell-ela edge-icell-services"

echo "============================================"
echo "Test: namespace overlay (prepare-namespaces, configure-mesh)"
echo "============================================"

# The SAP restricted-resources bundles create the namespaces; both tasks only
# overlay labels/annotations on the namespaces that exist and never create one.

# Write fake oc rules: the listed namespaces exist (and are Active), every
# other "get namespace <ns> --ignore-not-found" prints nothing (absent).
# Usage: namespace_rules RULES_FILE NS...
namespace_rules() {
  local RULES="$1" NS
  shift
  : > "${RULES}"
  for NS in "$@"; do
    printf 'get namespace %s --ignore-not-found -o name\t0\tnamespace/%s\n' "${NS}" "${NS}" >> "${RULES}"
    printf 'get namespace %s -o jsonpath*\t0\tActive\n' "${NS}" >> "${RULES}"
  done
}

run_prepare() {
  run_task "${PREPARE_YAML}" \
    --param hostedClusterName=test-cluster \
    --from '# --- Overlay labels and annotations on the namespaces the SAP bundles created ---'
}

run_mesh() {
  run_task "${MESH_YAML}" \
    --param hostedClusterName=test-cluster \
    --from '# --- Label application namespaces to join the mesh ---' \
    --to '# --- Wait for Service Mesh control plane to be ready ---'
}

echo ""
echo "Test: prepare_elm_phase_configures_only_edgelm"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
namespace_rules "${FAKE_OC_RULES}" edgelm
run_prepare
assert_rc 0
assert_called '^label namespace edgelm istio-injection=enabled edgelm.sap.com/product=edgelm --overwrite$'
assert_called '^annotate namespace edgelm openshift.io/sa.scc.supplemental-groups=67000/1000 --overwrite$'
assert_not_called 'create namespace'
assert_not_called 'apply -f -'
assert_not_called '^(label|annotate) namespace (edge-icell|edge-icell-secrets|edge-icell-ela|edge-icell-services|istio-gateways) '
grep -q 'edge-icell: not created yet, skipped' <<< "${TASK_OUT}" || fail "skip message missing"
grep -q 'Configured 1 namespaces; skipped 5 not created yet' <<< "${TASK_OUT}" || fail "summary missing"
echo "✅ PASS: prepare_elm_phase_configures_only_edgelm"

echo ""
echo "Test: prepare_all_present_configures_all"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
# shellcheck disable=SC2086
namespace_rules "${FAKE_OC_RULES}" ${ALL_NAMESPACES}
run_prepare
assert_rc 0
for NS in edgelm edge-icell edge-icell-ela edge-icell-services istio-gateways; do
  assert_called "^label namespace ${NS} istio-injection=enabled edgelm.sap.com/product=edgelm --overwrite$"
done
assert_called '^label namespace edge-icell-secrets edgelm.sap.com/product=edgelm --overwrite$'
assert_not_called '^label namespace edge-icell-secrets istio-injection'
assert_called '^annotate namespace edge-icell openshift.io/sa.scc.uid-range=10000/100 --overwrite$'
assert_called '^annotate namespace edge-icell-ela openshift.io/sa.scc.uid-range=100000/1000 --overwrite$'
assert_called '^annotate namespace edge-icell-services openshift.io/sa.scc.supplemental-groups=1000002/1000 --overwrite$'
assert_not_called 'create namespace'
grep -q 'Configured 6 namespaces; skipped 0 not created yet' <<< "${TASK_OUT}" || fail "summary missing"
echo "✅ PASS: prepare_all_present_configures_all"

echo ""
echo "Test: prepare_none_present_fails"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
: > "${FAKE_OC_RULES}"
run_prepare
[[ "${TASK_RC}" -ne 0 ]] || fail "expected failure when no SAP namespace exists"
grep -q 'None of the SAP namespaces exist' <<< "${TASK_OUT}" || fail "none-present message"
assert_not_called '^(label|annotate) namespace'
assert_not_called 'create namespace'
echo "✅ PASS: prepare_none_present_fails"

echo ""
echo "Test: prepare_oc_error_is_not_absence"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
printf 'get namespace edgelm --ignore-not-found -o name\t1\tError from server (Forbidden)\n' > "${FAKE_OC_RULES}"
run_prepare
[[ "${TASK_RC}" -ne 0 ]] || fail "an oc error must fail the task, not count as absent"
assert_not_called '^label namespace'
echo "✅ PASS: prepare_oc_error_is_not_absence"

echo ""
echo "Test: mesh_elm_phase_labels_only_edgelm"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
namespace_rules "${FAKE_OC_RULES}" edgelm
run_mesh
assert_rc 0
assert_called '^label namespace edgelm istio-discovery=enabled istio-injection=enabled --overwrite$'
assert_not_called '^label namespace (edge-icell|edge-icell-services|edge-icell-secrets|edge-icell-ela|istio-gateways) '
grep -q 'istio-gateways: not created yet, skipped' <<< "${TASK_OUT}" || fail "skip message missing"
echo "✅ PASS: mesh_elm_phase_labels_only_edgelm"

echo ""
echo "Test: mesh_none_present_fails"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
: > "${FAKE_OC_RULES}"
run_mesh
[[ "${TASK_RC}" -ne 0 ]] || fail "expected failure when no SAP namespace exists"
grep -q 'None of the SAP namespaces exist' <<< "${TASK_OUT}" || fail "none-present message"
assert_not_called '^label namespace'
echo "✅ PASS: mesh_none_present_fails"

echo ""
echo "Test: mesh_all_present_labels_all"
echo "--------------------------------------------"
FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
export FAKE_OC_LOG FAKE_OC_RULES
# shellcheck disable=SC2086
namespace_rules "${FAKE_OC_RULES}" ${ALL_NAMESPACES}
run_mesh
assert_rc 0
for NS in ${ALL_NAMESPACES}; do
  assert_called "^label namespace ${NS} istio-discovery=enabled istio-injection=enabled --overwrite$"
done
echo "✅ PASS: mesh_all_present_labels_all"

echo ""
echo "✅ ALL TESTS PASSED"
