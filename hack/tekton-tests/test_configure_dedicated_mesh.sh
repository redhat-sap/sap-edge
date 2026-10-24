#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: ossm3-configure-dedicated-mesh"
echo "============================================"

# Test case: secrets_gets_discovery_not_rev
# Verifies that when selecting namespaces by edgelm.sap.com/product=edgelm,
# ALL SAP namespaces (including secrets) get the discovery label,
# but NOT the istio.io/rev label.
echo ""
echo "Test: secrets_gets_discovery_not_rev"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

# Set up fake oc rules
# Use printf to properly encode \n in the multi-line output
printf 'get namespace -l edgelm.sap.com/product=edgelm*\t0\tedgelm\\nedge-icell-1\\nedge-icell-secrets-1\\nistio-gateways-1\n' > "${FAKE_OC_RULES}"
printf 'label namespace *\t0\tnamespace/test labeled\n' >> "${FAKE_OC_RULES}"

export FAKE_OC_LOG FAKE_OC_RULES

# Run the labeling section of the task
run_task ../../.tekton/tasks/ossm3-configure-dedicated-mesh-task.yaml \
  --param hostedClusterName=test-cluster \
  --param hostedClusterNamespace=clusters \
  --from '# --- Label the dedicated control plane namespace' \
  --to '# --- Create ServiceEntry' \
  --drop '# Install' 'oc version --client' \
  --drop '# Read proxy config' 'fi' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract kubeconfig for hosted cluster' 'connected to hosted cluster' \
  --drop '# --- Wait for OSSM3 CRDs' 'All OSSM3 CRDs are available' \
  --drop '# --- Create CNI namespace' 'IstioCNI resource created' \
  --drop '# --- Create dedicated SAP mesh namespace' 'oc apply -f -' \
  --drop '# --- Create the dedicated Istio control plane' 'Dedicated Istio control plane resource created'

# Verify the task succeeded
assert_rc 0

# Assert that edge-icell-secrets-1 got the discovery label
assert_called "label namespace edge-icell-secrets-1 istio-discovery=sap-edge-mesh --overwrite"

# Assert that edge-icell-secrets-1 did NOT get the istio.io/rev label
assert_not_called "label namespace edge-icell-secrets-1.*istio.io/rev"

# Assert that all SAP namespaces got the discovery label
assert_called "label namespace edgelm istio-discovery=sap-edge-mesh --overwrite"
assert_called "label namespace edge-icell-1 istio-discovery=sap-edge-mesh --overwrite"
assert_called "label namespace istio-gateways-1 istio-discovery=sap-edge-mesh --overwrite"

echo "✅ PASS: secrets namespace gets discovery label (not rev)"

# Test case: none_found_fails
# Verifies that when no namespaces are found, the task fails with an appropriate error
echo ""
echo "Test: none_found_fails"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

# Set up fake oc rules with empty namespace list
printf 'get namespace -l edgelm.sap.com/product=edgelm*\t0\t\n' > "${FAKE_OC_RULES}"
printf 'label namespace *\t0\tnamespace/test labeled\n' >> "${FAKE_OC_RULES}"

export FAKE_OC_LOG FAKE_OC_RULES

# Run the labeling section of the task
run_task ../../.tekton/tasks/ossm3-configure-dedicated-mesh-task.yaml \
  --param hostedClusterName=test-cluster \
  --param hostedClusterNamespace=clusters \
  --from '# --- Label the dedicated control plane namespace' \
  --to '# --- Create ServiceEntry' \
  --drop '# Install' 'oc version --client' \
  --drop '# Read proxy config' 'fi' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract kubeconfig for hosted cluster' 'connected to hosted cluster' \
  --drop '# --- Wait for OSSM3 CRDs' 'All OSSM3 CRDs are available' \
  --drop '# --- Create CNI namespace' 'IstioCNI resource created' \
  --drop '# --- Create dedicated SAP mesh namespace' 'oc apply -f -' \
  --drop '# --- Create the dedicated Istio control plane' 'Dedicated Istio control plane resource created'

# Verify the task failed
if [[ "${TASK_RC}" -eq 0 ]]; then
  echo "❌ FAIL: task should have failed when no namespaces found"
  exit 1
fi

# Verify the error message mentions the label selector
if ! echo "${TASK_OUT}" | grep -qF "No namespaces labeled edgelm.sap.com/product=edgelm"; then
  echo "❌ FAIL: error message should mention 'edgelm.sap.com/product=edgelm'"
  echo "Actual output:"
  echo "${TASK_OUT}"
  exit 1
fi

echo "✅ PASS: task fails when no namespaces found"

echo ""
echo "✅ ALL TESTS PASSED"
