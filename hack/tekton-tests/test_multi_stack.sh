#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

MESH_TASK=../../.tekton/tasks/ossm3-configure-multi-stack-mesh-task.yaml
PREP_TASK=../../.tekton/tasks/ossm3-prepare-namespaces-multi-stack-task.yaml

echo "============================================"
echo "Test: topology B multi-stack mesh and namespace tasks"
echo "============================================"

# Two Edge Nodes on one cluster: stack 1 has edge-node-id A, stack 2 has B.
# "<name> <edge-node-id>" per line, as returned by the stack discovery query.
TWO_STACKS="edgelm-1 A
edge-icell-1 A
edge-icell-secrets-1 A
edge-icell-ela-1 A
edge-icell-services-1 A
istio-gateways-1 A
edgelm-2 B
edge-icell-2 B
edge-icell-secrets-2 B
edge-icell-ela-2 B
edge-icell-services-2 B
istio-gateways-2 B"
STACK_NAMESPACES=$(awk '{print $1}' <<< "${TWO_STACKS}")

new_case() {
  echo ""
  echo "Test: $1"
  echo "--------------------------------------------"
  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  RESULTS_DIR=$(tmp_dir)
  WORKSPACE_DIR=$(tmp_dir)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR
}

# Rules shared by both tasks: hosted kubeconfig + stack discovery answer
# ($1, multi-line; joined with literal \n that fake oc expands).
base_rules() {
  printf 'get secret c1-admin-kubeconfig -n clusters*\t0\tYWJjCg==\n'
  printf 'get nodes*\t0\tnode1\n'
  printf 'get namespace -l edgelm.sap.com/product=edgelm -o jsonpath=*\t0\t%s\n' \
    "$(awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }' <<< "$1")"
}

# Mesh task: CRDs present at once; Istio selectors as given ($1, default: disjoint).
mesh_rules() {
  printf 'get crd *\t0\tcrd\n'
  printf 'get istios.sailoperator.io -A -o jsonpath=*\t0\t%s\n' \
    "${1:-sap-mesh-istio-1: sap-edge-mesh-1\\nsap-mesh-istio-2: sap-edge-mesh-2}"
}

# Prepare task: active revisions from the Istio status, fresh bundle labels.
prep_rules() {
  printf 'get istio sap-mesh-istio-1 -n istio-system-sap-edge-1 -o jsonpath=*\t0\tsap-mesh-istio-1\n'
  printf 'get istio sap-mesh-istio-2 -n istio-system-sap-edge-2 -o jsonpath=*\t0\tsap-mesh-istio-2-v1-24\n'
  printf 'get namespace edge-icell-secrets-* -o jsonpath=*\t0\t/\n'
  printf 'get namespace * -o jsonpath=*\t0\tenabled/\n'
}

# run_on TASK_YAML [extra extract args...]
run_on() {
  local TASK_YAML="$1"
  shift
  run_task "${TASK_YAML}" --param hostedClusterName=c1 --results-dir "${RESULTS_DIR}" \
    --workspace-dir "source=${WORKSPACE_DIR}" --drop '# Install required tools' 'oc version --client' "$@"
}

# The single captured manifest whose content matches every given pattern.
manifest_with() {
  local F P MATCH="" COUNT=0
  for F in "${FAKE_OC_STDIN_DIR}"/*.yaml; do
    [[ -f "${F}" ]] || continue
    for P in "$@"; do grep -qE "${P}" "${F}" || continue 2; done
    MATCH="${F}"
    COUNT=$((COUNT + 1))
  done
  [[ "${COUNT}" -eq 1 ]] || fail "expected exactly one applied manifest matching '$*', found ${COUNT}"
  printf '%s' "${MATCH}"
}

count_manifests() {
  local N
  N=$( { grep -lE "$1" "${FAKE_OC_STDIN_DIR}"/*.yaml 2>/dev/null || true; } | wc -l | tr -d ' ')
  printf '%s' "${N}"
}

assert_stacks_result() {
  [[ -f "${RESULTS_DIR}/stacks" ]] || fail "result 'stacks' not written"
  local GOT
  GOT=$(cat "${RESULTS_DIR}/stacks")
  [[ "${GOT}" == "1 2" ]] || fail "result 'stacks' should be '1 2', got '${GOT}'"
  [[ "$(wc -c < "${RESULTS_DIR}/stacks" | tr -d ' ')" -eq 3 ]] || fail "result 'stacks' must not end with a newline"
}

expect_fail_with() {
  if [[ "${TASK_RC}" -eq 0 ]]; then
    echo "${TASK_OUT}"
    fail "task should have failed"
  fi
  if ! grep -qF -- "$1" <<< "${TASK_OUT}"; then
    echo "${TASK_OUT}"
    fail "output should contain '$1'"
  fi
}

# ---------------------------------------------------------------------------
new_case mesh_creates_one_control_plane_per_stack
{ base_rules "${TWO_STACKS}"; mesh_rules; } > "${FAKE_OC_RULES}"
run_on "${MESH_TASK}"
[[ "${TASK_RC}" -eq 0 ]] || echo "${TASK_OUT}"
assert_rc 0
for N in 1 2; do
  F=$(manifest_with '^kind: Istio$' "^  name: sap-mesh-istio-${N}$")
  assert_file_contains "${F}" "^  namespace: istio-system-sap-edge-${N}$"
  assert_file_contains "${F}" "istio-discovery: sap-edge-mesh-${N}$"
  if grep -q ISTIO_META_DNS_CAPTURE "${F}"; then fail "no proxy: Istio ${N} must not capture DNS"; fi
  assert_called "label namespace istio-system-sap-edge-${N} istio-discovery=sap-edge-mesh-${N} --overwrite"
  assert_called "wait --for=condition=Ready istio/sap-mesh-istio-${N} -n istio-system-sap-edge-${N} --timeout=600s"
done
[[ "$(count_manifests '^kind: IstioCNI$')" -eq 1 ]] || fail "IstioCNI must be applied exactly once"
F=$(manifest_with '^kind: IstioCNI$')
assert_file_contains "${F}" "^  name: default$"
assert_file_contains "${F}" "^  namespace: istio-cni$"
[[ "$(count_manifests '^kind: ServiceEntry$')" -eq 0 ]] || fail "no proxy: no ServiceEntry expected"
assert_called "get istios.sailoperator.io -A -o jsonpath="
assert_stacks_result
echo "✅ PASS: mesh_creates_one_control_plane_per_stack"

# ---------------------------------------------------------------------------
new_case mesh_proxy_serviceentry_per_stack
{
  printf 'get secret corp-proxy -o jsonpath={.data.PROXY_HOST}\t0\t%s\n' "$(printf '%s' proxy.corp.example | base64)"
  printf 'get secret corp-proxy -o jsonpath={.data.PROXY_PORT}\t0\t%s\n' "$(printf '%s' 8080 | base64)"
  printf 'get secret corp-proxy -o jsonpath={.data.PROXY_IP}\t0\t%s\n' "$(printf '%s' '10.0.0.5, 10.0.0.6' | base64)"
  printf 'get secret corp-proxy\t0\tsecret/corp-proxy\n'
  base_rules "${TWO_STACKS}"
  mesh_rules
} > "${FAKE_OC_RULES}"
run_on "${MESH_TASK}" --param proxySecretName=corp-proxy
[[ "${TASK_RC}" -eq 0 ]] || echo "${TASK_OUT}"
assert_rc 0
for N in 1 2; do
  F=$(manifest_with '^kind: ServiceEntry$' "^  namespace: edgelm-${N}$")
  assert_file_contains "${F}" "^  name: allow-http-proxy$"
  assert_file_contains "${F}" "^    - proxy.corp.example$"
  assert_file_contains "${F}" "^    - 10.0.0.5$"
  assert_file_contains "${F}" "^    - 10.0.0.6$"
  assert_file_contains "${F}" "number: 8080$"
  F=$(manifest_with '^kind: Istio$' "^  name: sap-mesh-istio-${N}$")
  assert_file_contains "${F}" 'ISTIO_META_DNS_CAPTURE: "true"'
  assert_file_contains "${F}" 'ISTIO_META_DNS_AUTO_ALLOCATE: "true"'
  assert_file_contains "${F}" "istio-discovery: sap-edge-mesh-${N}$"
done
[[ "$(count_manifests '^kind: ServiceEntry$')" -eq 2 ]] || fail "exactly one ServiceEntry per stack expected"
echo "✅ PASS: mesh_proxy_serviceentry_per_stack"

# ---------------------------------------------------------------------------
new_case mesh_overlapping_selectors_fails
{ base_rules "${TWO_STACKS}"; mesh_rules 'sap-mesh-istio-1: sap-edge-mesh-1\nsap-mesh-istio-2: sap-edge-mesh-2\nlegacy-mesh: sap-edge-mesh-2'; } > "${FAKE_OC_RULES}"
run_on "${MESH_TASK}"
expect_fail_with "sap-mesh-istio-2 and legacy-mesh both select istio-discovery=sap-edge-mesh-2"
assert_not_called "^wait "
echo "✅ PASS: mesh_overlapping_selectors_fails"

# ---------------------------------------------------------------------------
# Stack validation is shared (identical block) by both tasks: run every case on both.
for TASK in "${MESH_TASK}" "${PREP_TASK}"; do
  T=$(basename "${TASK}" -task.yaml)
  new_case "validation_unsuffixed_fails (${T})"
  { base_rules "${TWO_STACKS}"$'\n'"edge-icell A"; mesh_rules; prep_rules; } > "${FAKE_OC_RULES}"
  run_on "${TASK}"
  expect_fail_with "SAP namespace edge-icell has no -<N> stack suffix"
  assert_not_called "^(apply|label|annotate) "
  echo "✅ PASS: validation_unsuffixed_fails (${T})"

  new_case "validation_missing_elm_fails (${T})"
  { base_rules "$(grep -v '^edgelm-2 ' <<< "${TWO_STACKS}")"; mesh_rules; prep_rules; } > "${FAKE_OC_RULES}"
  run_on "${TASK}"
  expect_fail_with "Stack 2 has no edgelm-2 namespace"
  assert_not_called "^(apply|label|annotate) "
  echo "✅ PASS: validation_missing_elm_fails (${T})"

  new_case "validation_mixed_node_ids_fails (${T})"
  { base_rules "${TWO_STACKS/istio-gateways-2 B/istio-gateways-2 C}"; mesh_rules; prep_rules; } > "${FAKE_OC_RULES}"
  run_on "${TASK}"
  expect_fail_with "Stack 2: istio-gateways-2 has edgelm.sap.com/edge-node-id C"
  assert_not_called "^(apply|label|annotate) "
  echo "✅ PASS: validation_mixed_node_ids_fails (${T})"

  new_case "validation_shared_node_id_fails (${T})"
  { base_rules "${TWO_STACKS// B/ A}"; mesh_rules; prep_rules; } > "${FAKE_OC_RULES}"
  run_on "${TASK}"
  expect_fail_with "Stacks 1 and 2 share edgelm.sap.com/edge-node-id A"
  assert_not_called "^(apply|label|annotate) "
  echo "✅ PASS: validation_shared_node_id_fails (${T})"

  new_case "validation_missing_node_id_fails (${T})"
  { base_rules "${TWO_STACKS/edge-icell-ela-1 A/edge-icell-ela-1 }"; mesh_rules; prep_rules; } > "${FAKE_OC_RULES}"
  run_on "${TASK}"
  expect_fail_with "SAP namespace edge-icell-ela-1 has no edgelm.sap.com/edge-node-id label"
  assert_not_called "^(apply|label|annotate) "
  echo "✅ PASS: validation_missing_node_id_fails (${T})"

  new_case "validation_none_found_fails (${T})"
  { base_rules ""; mesh_rules; prep_rules; } > "${FAKE_OC_RULES}"
  run_on "${TASK}"
  expect_fail_with "No namespaces labeled edgelm.sap.com/product=edgelm found"
  assert_not_called "^(apply|label|annotate) "
  echo "✅ PASS: validation_none_found_fails (${T})"
done

# ---------------------------------------------------------------------------
new_case discovery_block_identical
discovery_block() {
  sed -n '/# --- Discover Edge Node stacks/,/# --- End of stack discovery/p' "$1"
}
[[ "$(discovery_block "${MESH_TASK}" | wc -l | tr -d ' ')" -gt 5 ]] || fail "stack discovery block markers not found in ${MESH_TASK}"
if ! diff <(discovery_block "${MESH_TASK}") <(discovery_block "${PREP_TASK}"); then
  fail "stack discovery block differs between the two multi-stack tasks"
fi
echo "✅ PASS: discovery_block_identical"

# ---------------------------------------------------------------------------
new_case prepare_labels_per_stack
{ base_rules "${TWO_STACKS}"; prep_rules; } > "${FAKE_OC_RULES}"
run_on "${PREP_TASK}"
[[ "${TASK_RC}" -eq 0 ]] || echo "${TASK_OUT}"
assert_rc 0
assert_called "label namespace edge-icell-2 istio.io/rev=sap-mesh-istio-2-v1-24 --overwrite"
assert_called "label namespace edge-icell-1 istio.io/rev=sap-mesh-istio-1 --overwrite"
assert_called "label namespace edge-icell-secrets-1 istio-discovery=sap-edge-mesh-1 --overwrite"
for NS in ${STACK_NAMESPACES}; do
  N="${NS##*-}"
  assert_called "label namespace ${NS} istio-discovery=sap-edge-mesh-${N} --overwrite"
  assert_called "label namespace ${NS} istio-injection-$"
  case "${NS}" in
    edge-icell-secrets-*) ;;
    *-1) assert_called "label namespace ${NS} istio.io/rev=sap-mesh-istio-1 --overwrite" ;;
    *-2) assert_called "label namespace ${NS} istio.io/rev=sap-mesh-istio-2-v1-24 --overwrite" ;;
  esac
done
assert_not_called "label namespace edge-icell-secrets-[0-9]+ istio.io/rev"
assert_not_called "label namespace [a-z-]+-1 istio-discovery=sap-edge-mesh-2"
assert_not_called "label namespace [a-z-]+-2 istio-discovery=sap-edge-mesh-1"
assert_not_called "label namespace [a-z-]+-1 istio.io/rev=sap-mesh-istio-2"
assert_not_called "label namespace [a-z-]+-2 istio.io/rev=sap-mesh-istio-1 "
assert_not_called "^label .*edgelm\.sap\.com"
assert_called "annotate namespace edge-icell-ela-2 openshift.io/sa.scc.uid-range=100000/1000 --overwrite"
assert_called "annotate namespace edge-icell-ela-2 openshift.io/sa.scc.supplemental-groups=100002/1000 --overwrite"
assert_called "annotate namespace edgelm-1 openshift.io/sa.scc.supplemental-groups=67000/1000 --overwrite"
assert_not_called "annotate namespace edgelm-1 openshift.io/sa.scc.uid-range"
assert_called "annotate namespace edge-icell-1 openshift.io/sa.scc.uid-range=10000/100 --overwrite"
assert_called "annotate namespace edge-icell-services-2 openshift.io/sa.scc.uid-range=1000000/1000 --overwrite"
assert_not_called "annotate namespace (edge-icell-secrets|istio-gateways)-"
assert_called "get namespaces -l edgelm.sap.com/product=edgelm -L edgelm.sap.com/edge-node-id,istio-discovery,istio.io/rev,istio-injection"
assert_stacks_result
echo "✅ PASS: prepare_labels_per_stack"

# ---------------------------------------------------------------------------
new_case rerun_is_idempotent
{
  base_rules "${TWO_STACKS}"
  printf 'get istio sap-mesh-istio-1 -n istio-system-sap-edge-1 -o jsonpath=*\t0\tsap-mesh-istio-1\n'
  printf 'get istio sap-mesh-istio-2 -n istio-system-sap-edge-2 -o jsonpath=*\t0\tsap-mesh-istio-2-v1-24\n'
  printf 'get namespace edge-icell-secrets-* -o jsonpath=*\t0\t/\n'
  printf 'get namespace *-1 -o jsonpath=*\t0\t/sap-mesh-istio-1\n'
  printf 'get namespace *-2 -o jsonpath=*\t0\t/sap-mesh-istio-2-v1-24\n'
} > "${FAKE_OC_RULES}"
run_on "${PREP_TASK}"
[[ "${TASK_RC}" -eq 0 ]] || echo "${TASK_OUT}"
assert_rc 0
for NS in ${STACK_NAMESPACES}; do
  case "${NS}" in
    edge-icell-secrets-*) ;;
    *-1) assert_called "label namespace ${NS} istio.io/rev=sap-mesh-istio-1 --overwrite" ;;
    *-2) assert_called "label namespace ${NS} istio.io/rev=sap-mesh-istio-2-v1-24 --overwrite" ;;
  esac
done
assert_not_called "label namespace edge-icell-secrets-[0-9]+ istio.io/rev"
echo "✅ PASS: rerun_is_idempotent"

# ---------------------------------------------------------------------------
# Even if a secrets namespace carries injection labels, it never gets istio.io/rev
# and a stale istio.io/rev is removed.
new_case secrets_never_injected
{
  base_rules "${TWO_STACKS}"
  printf 'get istio sap-mesh-istio-1 -n istio-system-sap-edge-1 -o jsonpath=*\t0\tsap-mesh-istio-1\n'
  printf 'get istio sap-mesh-istio-2 -n istio-system-sap-edge-2 -o jsonpath=*\t0\tsap-mesh-istio-2-v1-24\n'
  printf 'get namespace edge-icell-secrets-1 -o jsonpath=*\t0\tenabled/\n'
  printf 'get namespace edge-icell-secrets-2 -o jsonpath=*\t0\t/sap-mesh-istio-2-v1-24\n'
  printf 'get namespace * -o jsonpath=*\t0\tenabled/\n'
} > "${FAKE_OC_RULES}"
run_on "${PREP_TASK}"
[[ "${TASK_RC}" -eq 0 ]] || echo "${TASK_OUT}"
assert_rc 0
assert_not_called "label namespace edge-icell-secrets-[0-9]+ istio.io/rev="
assert_called "label namespace edge-icell-secrets-2 istio.io/rev-$"
assert_called "label namespace edge-icell-secrets-1 istio-injection-$"
assert_called "label namespace edge-icell-secrets-2 istio-discovery=sap-edge-mesh-2 --overwrite"
echo "✅ PASS: secrets_never_injected"

# ---------------------------------------------------------------------------
# Istio/IstioRevision are cluster-scoped: both meshes' revisions are listed,
# the one whose spec.namespace is the stack's control plane namespace wins.
new_case revision_fallback_to_istiorevisions
{
  base_rules "${TWO_STACKS}"
  printf 'get istio sap-mesh-istio-* -o jsonpath=*\t0\t\n'
  printf 'get istiorevisions -A -o jsonpath=*\t0\t%s\n' 'sap-mesh-istio-1 istio-system-sap-edge-1\nsap-mesh-istio-2-v1-25 istio-system-sap-edge-2'
  printf 'get namespace edge-icell-secrets-* -o jsonpath=*\t0\t/\n'
  printf 'get namespace * -o jsonpath=*\t0\tenabled/\n'
} > "${FAKE_OC_RULES}"
run_on "${PREP_TASK}"
[[ "${TASK_RC}" -eq 0 ]] || echo "${TASK_OUT}"
assert_rc 0
assert_called "label namespace edge-icell-2 istio.io/rev=sap-mesh-istio-2-v1-25 --overwrite"
assert_called "label namespace edge-icell-1 istio.io/rev=sap-mesh-istio-1 --overwrite"
echo "✅ PASS: revision_fallback_to_istiorevisions"

# ---------------------------------------------------------------------------
new_case revision_undetermined_fails
{
  base_rules "${TWO_STACKS}"
  printf 'get istio sap-mesh-istio-1 -n istio-system-sap-edge-1 -o jsonpath=*\t0\tsap-mesh-istio-1\n'
  printf 'get istio sap-mesh-istio-* -o jsonpath=*\t1\t\n'
  printf 'get istiorevisions -A -o jsonpath=*\t0\t%s\n' 'sap-mesh-istio-1 istio-system-sap-edge-1\nsap-mesh-istio-2-a istio-system-sap-edge-2\nsap-mesh-istio-2-b istio-system-sap-edge-2'
  printf 'get namespace * -o jsonpath=*\t0\tenabled/\n'
} > "${FAKE_OC_RULES}"
run_on "${PREP_TASK}"
expect_fail_with "Cannot determine the active revision of sap-mesh-istio-2"
assert_not_called "^(label|annotate) "
echo "✅ PASS: revision_undetermined_fails"

echo ""
echo "✅ ALL TESTS PASSED"
