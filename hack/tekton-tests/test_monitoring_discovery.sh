#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: Monitoring tasks namespace discovery"
echo "============================================"

# Test 1: hcp-enable-monitoring with default (fixed list)
echo ""
echo "Test 1: enable-monitoring defaults to fixed list"
echo "================================================"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get configmap cluster-monitoring-config *	0
get pods -n openshift-user-workload-monitoring *	0	NAME\npod-1	Running
get namespace edge-icell	0
get namespace edge-icell-services	0
get namespace edgelm	0
apply -f -	0	networkpolicy.networking.k8s.io/allow-from-openshift-user-workload-monitoring created
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

run_task ../../.tekton/tasks/hcp-enable-monitoring-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster' 'oc whoami' \
  --drop 'echo "🔐 Extracting kubeconfig' 'oc whoami' \
  --from '# Step 2:'

assert_rc 0
# Should apply NetworkPolicies to exactly the 3 default namespaces
assert_called "get namespace edge-icell"
assert_called "get namespace edge-icell-services"
assert_called "get namespace edgelm"
# Should NOT try to discover namespaces
assert_not_called "get namespace -l edgelm.sap.com/product=edgelm"

echo "✅ PASS: enable-monitoring defaults to fixed list"

# Test 2: hcp-enable-monitoring with discovery
echo ""
echo "Test 2: enable-monitoring discovers namespaces"
echo "================================================"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

{
  printf 'get configmap cluster-monitoring-config *\t0\t\n'
  printf 'get pods -n openshift-user-workload-monitoring *\t0\tNAME\\npod-1\tRunning\n'
  printf 'get namespace -l edgelm.sap.com/product=edgelm -o jsonpath*\t0\tedgelm-1\\nedgelm-2\\nedge-icell-1\\nedge-icell-secrets-1\\nedge-icell-services-1\\nedge-icell-2\\nedge-icell-ela-2\\nistio-gateways-1\n'
  printf 'get namespace edgelm-1\t0\t\n'
  printf 'get namespace edgelm-2\t0\t\n'
  printf 'get namespace edge-icell-1\t0\t\n'
  printf 'get namespace edge-icell-2\t0\t\n'
  printf 'get namespace edge-icell-services-1\t0\t\n'
  printf 'apply -f -\t0\tnetworkpolicy.networking.k8s.io/allow-from-openshift-user-workload-monitoring created\n'
} > "${FAKE_OC_RULES}"

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

run_task ../../.tekton/tasks/hcp-enable-monitoring-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param discoverNamespaces=true \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster' 'oc whoami' \
  --drop 'echo "🔐 Extracting kubeconfig' 'oc whoami' \
  --from '# Step 2:' \

assert_rc 0
# Should discover namespaces
assert_called "get namespace -l edgelm.sap.com/product=edgelm"
# Should check only the target role namespaces (edgelm, edge-icell, edge-icell-services)
assert_called "get namespace edgelm-1"
assert_called "get namespace edgelm-2"
assert_called "get namespace edge-icell-1"
assert_called "get namespace edge-icell-2"
assert_called "get namespace edge-icell-services-1"
# Should NOT check the excluded roles
assert_not_called "get namespace edge-icell-secrets-1"
assert_not_called "get namespace edge-icell-ela-2"
assert_not_called "get namespace istio-gateways-1"

# Check that NetworkPolicies were applied to the correct namespaces
# We can check by examining the YAML stdin captured by fake oc
APPLIED_COUNT=$(find "${FAKE_OC_STDIN_DIR}" -name "*.yaml" -o -name "stdin.*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "${APPLIED_COUNT}" -eq 0 ]]; then
  fail "No NetworkPolicies were applied"
fi

# Verify the applied NetworkPolicies contain the expected namespaces
APPLIED_NP=$(cat "${FAKE_OC_STDIN_DIR}"/* 2>/dev/null || echo "")
if ! echo "${APPLIED_NP}" | grep -q "namespace: edgelm-1"; then
  fail "NetworkPolicy for edgelm-1 not found"
fi
if ! echo "${APPLIED_NP}" | grep -q "namespace: edgelm-2"; then
  fail "NetworkPolicy for edgelm-2 not found"
fi
if ! echo "${APPLIED_NP}" | grep -q "namespace: edge-icell-1"; then
  fail "NetworkPolicy for edge-icell-1 not found"
fi
if ! echo "${APPLIED_NP}" | grep -q "namespace: edge-icell-2"; then
  fail "NetworkPolicy for edge-icell-2 not found"
fi
if ! echo "${APPLIED_NP}" | grep -q "namespace: edge-icell-services-1"; then
  fail "NetworkPolicy for edge-icell-services-1 not found"
fi
# Should NOT have policies for excluded namespaces
if echo "${APPLIED_NP}" | grep -q "namespace: edge-icell-secrets-1"; then
  fail "NetworkPolicy for edge-icell-secrets-1 should not be created"
fi
if echo "${APPLIED_NP}" | grep -q "namespace: edge-icell-ela-2"; then
  fail "NetworkPolicy for edge-icell-ela-2 should not be created"
fi
if echo "${APPLIED_NP}" | grep -q "namespace: istio-gateways-1"; then
  fail "NetworkPolicy for istio-gateways-1 should not be created"
fi

echo "✅ PASS: enable-monitoring discovers and applies policies to correct namespaces"

# Test 3: hcp-verify-monitoring with default (fixed list)
echo ""
echo "Test 3: verify-monitoring defaults to fixed list"
echo "================================================="

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

cat > "${FAKE_OC_RULES}" <<'EOF'
get namespace edge-icell	0
get namespace edge-icell-services	0
get namespace edgelm	0
get servicemonitor -n edge-icell -o json	0	{"items":[{"metadata":{"name":"sm-1"}}]}
get servicemonitor -n edge-icell-services -o json	0	{"items":[{"metadata":{"name":"sm-2"}}]}
get servicemonitor -n edgelm -o json	0	{"items":[{"metadata":{"name":"sm-3"}}]}
get podmonitor -n edge-icell -o json	0	{"items":[]}
get podmonitor -n edge-icell-services -o json	0	{"items":[]}
get podmonitor -n edgelm -o json	0	{"items":[]}
get route thanos-querier *	1
EOF

export FAKE_OC_LOG FAKE_OC_RULES

run_task ../../.tekton/tasks/hcp-verify-monitoring-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster' 'oc whoami' \
  --drop 'echo "🔐 Extracting kubeconfig' 'oc whoami' \
  --from '# Step 1:'

assert_rc 0
# Should query ServiceMonitors from exactly the 3 default namespaces
assert_called "get servicemonitor -n edge-icell"
assert_called "get servicemonitor -n edge-icell-services"
assert_called "get servicemonitor -n edgelm"
# Should NOT try to discover namespaces
assert_not_called "get namespace -l edgelm.sap.com/product=edgelm"

echo "✅ PASS: verify-monitoring defaults to fixed list"

# Test 4: hcp-verify-monitoring with discovery
echo ""
echo "Test 4: verify-monitoring discovers namespaces"
echo "==============================================="

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

{
  printf 'get namespace -l edgelm.sap.com/product=edgelm -o jsonpath*\t0\tedgelm-1\\nedgelm-2\\nedge-icell-1\\nedge-icell-secrets-1\\nedge-icell-services-1\\nedge-icell-2\\nedge-icell-ela-2\\nistio-gateways-1\n'
  printf 'get namespace edgelm-1\t0\t\n'
  printf 'get namespace edgelm-2\t0\t\n'
  printf 'get namespace edge-icell-1\t0\t\n'
  printf 'get namespace edge-icell-2\t0\t\n'
  printf 'get namespace edge-icell-services-1\t0\t\n'
  printf 'get servicemonitor -n edgelm-1 -o json\t0\t{"items":[{"metadata":{"name":"sm-1"}}]}\n'
  printf 'get servicemonitor -n edgelm-2 -o json\t0\t{"items":[{"metadata":{"name":"sm-2"}}]}\n'
  printf 'get servicemonitor -n edge-icell-1 -o json\t0\t{"items":[{"metadata":{"name":"sm-3"}}]}\n'
  printf 'get servicemonitor -n edge-icell-2 -o json\t0\t{"items":[{"metadata":{"name":"sm-4"}}]}\n'
  printf 'get servicemonitor -n edge-icell-services-1 -o json\t0\t{"items":[{"metadata":{"name":"sm-5"}}]}\n'
  printf 'get podmonitor -n edgelm-1 -o json\t0\t{"items":[]}\n'
  printf 'get podmonitor -n edgelm-2 -o json\t0\t{"items":[]}\n'
  printf 'get podmonitor -n edge-icell-1 -o json\t0\t{"items":[]}\n'
  printf 'get podmonitor -n edge-icell-2 -o json\t0\t{"items":[]}\n'
  printf 'get podmonitor -n edge-icell-services-1 -o json\t0\t{"items":[]}\n'
  printf 'get route thanos-querier *\t1\t\n'
} > "${FAKE_OC_RULES}"

export FAKE_OC_LOG FAKE_OC_RULES

run_task ../../.tekton/tasks/hcp-verify-monitoring-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param discoverNamespaces=true \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster' 'oc whoami' \
  --drop 'echo "🔐 Extracting kubeconfig' 'oc whoami' \
  --from '# Step 1:'

assert_rc 0
# Should discover namespaces
assert_called "get namespace -l edgelm.sap.com/product=edgelm"
# Should query ServiceMonitors from the discovered target role namespaces
assert_called "get servicemonitor -n edgelm-1"
assert_called "get servicemonitor -n edgelm-2"
assert_called "get servicemonitor -n edge-icell-1"
assert_called "get servicemonitor -n edge-icell-2"
assert_called "get servicemonitor -n edge-icell-services-1"
# Should NOT query the excluded namespaces
assert_not_called "get servicemonitor -n edge-icell-secrets-1"
assert_not_called "get servicemonitor -n edge-icell-ela-2"
assert_not_called "get servicemonitor -n istio-gateways-1"

echo "✅ PASS: verify-monitoring discovers and queries correct namespaces"

echo ""
echo "============================================"
echo "✅ ALL TESTS PASSED"
echo "============================================"
