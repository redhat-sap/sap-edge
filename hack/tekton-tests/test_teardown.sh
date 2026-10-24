#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: hcp-teardown pipeline artifacts"
echo "============================================"

# Run the pipeline-artifact cleanup section of hcp-teardown for cluster c1.
run_cleanup() {
  run_task ../../.tekton/tasks/hcp-teardown-task.yaml \
    --param hostedClusterName=c1 \
    --param hostedClusterNamespace=clusters \
    --namespace pipeline-ns \
    --from '# Clean up ConfigMap and Cloud Connector secret' \
    --to '# Clean up Loki OBC'
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
  fi
}

# Test case: per_cell_and_per_stack_artifacts
# Deletes the cells' ConfigMaps, the stacks' kubeconfig Secrets and the
# per-instance credentials Secrets in the pipeline namespace; keeps the
# single-EIC deletions; touches no other cluster's names.
echo ""
echo "Test: per_cell_and_per_stack_artifacts"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
cat > "${FAKE_OC_RULES}" <<'EOF'
get hostedcluster -A -o jsonpath=*	0	c1 c10 other
delete configmap/cluster-info-hcp-c1-1 -n pipeline-ns --ignore-not-found=true	0	configmap "cluster-info-hcp-c1-1" deleted
EOF
export FAKE_OC_LOG FAKE_OC_RULES

run_cleanup
assert_rc 0

# Unchanged single-EIC cleanup
assert_called "^delete configmap cluster-info-hcp-c1 --ignore-not-found=true$"
assert_called "^delete secret eic-credentials-hcp-c1 --ignore-not-found=true$"
assert_called "^delete secret cloud-connector-c1 --ignore-not-found=true$"

for N in 1 2; do
  assert_called "^delete configmap/cluster-info-hcp-c1-${N} -n pipeline-ns --ignore-not-found=true$"
  assert_called "^delete configmap/route-info-hcp-c1-${N} -n pipeline-ns --ignore-not-found=true$"
  assert_called "^delete secret/edgelm-kubeconfig-generated-c1-${N} -n pipeline-ns --ignore-not-found=true$"
  assert_called "^delete secret/eic-credentials-hcp-c1-eic-${N} -n pipeline-ns --ignore-not-found=true$"
done

# Exactly these 3 + 8 deletions, nothing broader (no label/prefix sweeps)
DELETES=$(grep -c "^delete " "${FAKE_OC_LOG}" || true)
[[ "${DELETES}" -eq 11 ]] || { cat "${FAKE_OC_LOG}"; fail "expected 11 deletions, got ${DELETES}"; }
assert_not_called "c10"
assert_not_called "other"
assert_not_called "delete .*(--all|-l |--selector)"

# Real deletions are reported, missing names stay silent
grep -qF 'configmap "cluster-info-hcp-c1-1" deleted' <<< "${TASK_OUT}" || fail "deletion not reported"

echo "✅ PASS: per_cell_and_per_stack_artifacts"

# Test case: name_clash_with_live_cluster_is_skipped
# A live HostedCluster c1-2 owns cluster-info-hcp-c1-2 & co. as its default
# names; c1's teardown must leave them alone but still clean up N=1.
echo ""
echo "Test: name_clash_with_live_cluster_is_skipped"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
cat > "${FAKE_OC_RULES}" <<'EOF'
get hostedcluster -A -o jsonpath=*	1
get hostedcluster -n clusters -o jsonpath=*	0	c1 c1-2
EOF
export FAKE_OC_LOG FAKE_OC_RULES

run_cleanup
assert_rc 0

assert_called "^delete configmap/cluster-info-hcp-c1-1 -n pipeline-ns"
assert_called "^delete secret/edgelm-kubeconfig-generated-c1-1 -n pipeline-ns"
assert_called "^delete secret/eic-credentials-hcp-c1-eic-2 -n pipeline-ns"
assert_not_called "cluster-info-hcp-c1-2"
assert_not_called "route-info-hcp-c1-2"
assert_not_called "edgelm-kubeconfig-generated-c1-2"
grep -qF "Skipping configmap/cluster-info-hcp-c1-2: HostedCluster 'c1-2' exists" <<< "${TASK_OUT}" \
  || fail "skipped name clash is not logged"

echo "✅ PASS: name_clash_with_live_cluster_is_skipped"

echo ""
echo "✅ ALL TESTS PASSED"
