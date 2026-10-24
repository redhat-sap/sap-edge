#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: Gateway-aware ConfigMap and Route"
echo "============================================"

# Test case: configmap_defaults
# No new params → creates cluster-info-hcp-c1 with host=eic.apps.test.example
echo ""
echo "Test: configmap_defaults"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

# Set up fake oc rules (more specific rules first)
cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get clusterversion*	1
get ingresscontroller default -n openshift-ingress-operator -o jsonpath*	0	apps.test.example
get ingresscontroller default -n openshift-ingress-operator -o json*	0	{"status":{"domain":"apps.test.example"}}
get svc istio-ingressgateway -n istio-system -o jsonpath=\{.status.loadBalancer.ingress\[0\].ip\}	0
get svc istio-ingressgateway -n istio-system -o jsonpath=\{.status.loadBalancer.ingress\[0\].hostname\}	0
get svc istio-ingressgateway -n istio-system	0
get svc istio-ingressgateway -n istio-gateways -o jsonpath=\{.status.loadBalancer.ingress\[0\].ip\}	0	10.0.0.5
get svc istio-ingressgateway -n istio-gateways	0
get svc --all-namespaces -o json*	0	{"items":[{"metadata":{"name":"istio-ingressgateway","namespace":"istio-gateways"},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.5"}]}}}]}
get hpa istio-ingressgateway -n istio-system	1
get hpa istio-ingressgateway -n istio-gateways -o jsonpath=\{.spec.minReplicas\}	0	1
get hpa istio-ingressgateway -n istio-gateways -o jsonpath=\{.spec.maxReplicas\}	0	3
get hpa istio-ingressgateway -n istio-gateways	0
patch hpa istio-ingressgateway -n istio-gateways*	0	patched
get svc -n clusters-c1 -o json*	0	{"items":[{"metadata":{"name":"lb-10-0-0-5"},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.5"}]}}}]}
get svc lb-10-0-0-5 -n clusters-c1 -o jsonpath=\{.spec.externalTrafficPolicy\}	0	Cluster
get svc lb-10-0-0-5 -n clusters-c1	0
patch svc lb-10-0-0-5 -n clusters-c1*	0	patched
delete configmap cluster-info-hcp-c1*	0	deleted
create configmap cluster-info-hcp-c1*	0	configmap/cluster-info-hcp-c1 created
get configmap cluster-info-hcp-c1 -o yaml*	0	name: cluster-info-hcp-c1
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

# Run the configmap task
RESULTS_DIR=$(tmp_dir)
run_task ../../.tekton/tasks/hcp-validate-and-create-configmap-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --results-dir "${RESULTS_DIR}" \
  --from 'INGRESS_DOMAIN=' \
  --to '# Generate summary' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract kubeconfig for hosted cluster' 'Hosted cluster kubeconfig extracted'

assert_rc 0
assert_called "create configmap cluster-info-hcp-c1 --from-literal=host=eic.apps.test.example"
# istio-system has the service but no IP, so the IP comes from istio-gateways
grep -qF "Gateway Namespace: istio-gateways" <<< "${TASK_OUT}" || fail "summary does not name gateway namespace istio-gateways"

echo "✅ PASS: configmap_defaults"

# Test case: configmap_hpa_cross_namespace
# Service in istio-gateways, HPA in istio-system → HPA should be found and patched
echo ""
echo "Test: configmap_hpa_cross_namespace"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1\nnode2
get clusterversion*	1
get ingresscontroller default -n openshift-ingress-operator -o jsonpath*	0	apps.test.example
get ingresscontroller default -n openshift-ingress-operator -o json*	0	{"status":{"domain":"apps.test.example"}}
get svc istio-ingressgateway -n istio-system -o jsonpath=\{.status.loadBalancer.ingress\[0\].ip\}	0
get svc istio-ingressgateway -n istio-system -o jsonpath=\{.status.loadBalancer.ingress\[0\].hostname\}	0
get svc istio-ingressgateway -n istio-system	0
get svc istio-ingressgateway -n istio-gateways -o jsonpath=\{.status.loadBalancer.ingress\[0\].ip\}	0	10.0.0.5
get svc istio-ingressgateway -n istio-gateways	0
get svc --all-namespaces -o json*	0	{"items":[{"metadata":{"name":"istio-ingressgateway","namespace":"istio-gateways"},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.5"}]}}}]}
get hpa istio-ingressgateway -n istio-system -o jsonpath=\{.spec.minReplicas\}	0	1
get hpa istio-ingressgateway -n istio-system -o jsonpath=\{.spec.maxReplicas\}	0	1
get hpa istio-ingressgateway -n istio-system	0
patch hpa istio-ingressgateway -n istio-system*	0	patched
get svc -n clusters-c1 -o json*	0	{"items":[{"metadata":{"name":"lb-10-0-0-5"},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.5"}]}}}]}
get svc lb-10-0-0-5 -n clusters-c1 -o jsonpath=\{.spec.externalTrafficPolicy\}	0	Cluster
get svc lb-10-0-0-5 -n clusters-c1	0
patch svc lb-10-0-0-5 -n clusters-c1*	0	patched
delete configmap cluster-info-hcp-c1*	0	deleted
create configmap cluster-info-hcp-c1*	0	configmap/cluster-info-hcp-c1 created
get configmap cluster-info-hcp-c1 -o yaml*	0	name: cluster-info-hcp-c1
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

RESULTS_DIR=$(tmp_dir)
run_task ../../.tekton/tasks/hcp-validate-and-create-configmap-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --results-dir "${RESULTS_DIR}" \
  --from 'INGRESS_DOMAIN=' \
  --to '# Generate summary' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract kubeconfig for hosted cluster' 'Hosted cluster kubeconfig extracted'

assert_rc 0
# Verify HPA was looked up in istio-system (not istio-gateways where service is)
assert_called "get hpa istio-ingressgateway -n istio-system"
assert_called "patch hpa istio-ingressgateway -n istio-system"

echo "✅ PASS: configmap_hpa_cross_namespace"

# Test case: configmap_cell2
# With gatewayNamespace=istio-gateways-2, hostPrefix=eic-2, configMapName=cluster-info-hcp-c1-2
# → looks only in istio-gateways-2, creates configmap with host=eic-2.apps.test.example
echo ""
echo "Test: configmap_cell2"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1\nnode2
get clusterversion*	1
get ingresscontroller default -n openshift-ingress-operator -o jsonpath*	0	apps.test.example
get ingresscontroller default -n openshift-ingress-operator -o json*	0	{"status":{"domain":"apps.test.example"}}
get svc istio-ingressgateway -n istio-gateways-2 -o jsonpath=\{.status.loadBalancer.ingress\[0\].ip\}	0	10.0.0.5
get svc istio-ingressgateway -n istio-gateways-2 -o jsonpath=\{.status.loadBalancer.ingress\[0\].hostname\}	0
get svc istio-ingressgateway -n istio-gateways-2	0
get hpa istio-ingressgateway -n istio-gateways-2 -o jsonpath=\{.spec.minReplicas\}	0	2
get hpa istio-ingressgateway -n istio-gateways-2 -o jsonpath=\{.spec.maxReplicas\}	0	3
get hpa istio-ingressgateway -n istio-gateways-2	0
patch hpa istio-ingressgateway -n istio-gateways-2*	0	patched
get svc -n clusters-c1 -o json*	0	{"items":[{"metadata":{"name":"lb-10-0-0-5"},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.5"}]}}}]}
get svc lb-10-0-0-5 -n clusters-c1 -o jsonpath=\{.spec.externalTrafficPolicy\}	0	Cluster
get svc lb-10-0-0-5 -n clusters-c1	0
patch svc lb-10-0-0-5 -n clusters-c1*	0	patched
delete configmap cluster-info-hcp-c1-2*	0	deleted
create configmap cluster-info-hcp-c1-2*	0	configmap/cluster-info-hcp-c1-2 created
get configmap cluster-info-hcp-c1-2 -o yaml*	0	name: cluster-info-hcp-c1-2
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

RESULTS_DIR=$(tmp_dir)
run_task ../../.tekton/tasks/hcp-validate-and-create-configmap-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param gatewayNamespace=istio-gateways-2 \
  --param hostPrefix=eic-2 \
  --param configMapName=cluster-info-hcp-c1-2 \
  --results-dir "${RESULTS_DIR}" \
  --from 'INGRESS_DOMAIN=' \
  --to '# Generate summary' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract kubeconfig for hosted cluster' 'Hosted cluster kubeconfig extracted'

assert_rc 0
assert_called "get svc istio-ingressgateway -n istio-gateways-2"
assert_not_called "get svc istio-ingressgateway -n istio-gateways-1"
assert_not_called "get svc istio-ingressgateway -n istio-system"
assert_called "create configmap cluster-info-hcp-c1-2 --from-literal=host=eic-2.apps.test.example --from-literal=ingressIP=10.0.0.5"
assert_called "get hpa istio-ingressgateway -n istio-gateways-2"
grep -qF "Gateway Namespace: istio-gateways-2" <<< "${TASK_OUT}" || fail "summary does not name gateway namespace istio-gateways-2"

echo "✅ PASS: configmap_cell2"

# Test case: configmap_cell_hpa_isolated
# With gatewayNamespace set, HPA lookup should ONLY check that namespace, not istio-system
echo ""
echo "Test: configmap_cell_hpa_isolated"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1\nnode2
get clusterversion*	1
get ingresscontroller default -n openshift-ingress-operator -o jsonpath*	0	apps.test.example
get ingresscontroller default -n openshift-ingress-operator -o json*	0	{"status":{"domain":"apps.test.example"}}
get svc istio-ingressgateway -n istio-gateways-2 -o jsonpath=\{.status.loadBalancer.ingress\[0\].ip\}	0	10.0.0.5
get svc istio-ingressgateway -n istio-gateways-2 -o jsonpath=\{.status.loadBalancer.ingress\[0\].hostname\}	0
get svc istio-ingressgateway -n istio-gateways-2	0
get hpa istio-ingressgateway -n istio-gateways-2	1
get svc -n clusters-c1 -o json*	0	{"items":[{"metadata":{"name":"lb-10-0-0-5"},"status":{"loadBalancer":{"ingress":[{"ip":"10.0.0.5"}]}}}]}
get svc lb-10-0-0-5 -n clusters-c1 -o jsonpath=\{.spec.externalTrafficPolicy\}	0	Cluster
get svc lb-10-0-0-5 -n clusters-c1	0
patch svc lb-10-0-0-5 -n clusters-c1*	0	patched
delete configmap cluster-info-hcp-c1-2*	0	deleted
create configmap cluster-info-hcp-c1-2*	0	configmap/cluster-info-hcp-c1-2 created
get configmap cluster-info-hcp-c1-2 -o yaml*	0	name: cluster-info-hcp-c1-2
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

RESULTS_DIR=$(tmp_dir)
run_task ../../.tekton/tasks/hcp-validate-and-create-configmap-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param gatewayNamespace=istio-gateways-2 \
  --param hostPrefix=eic-2 \
  --param configMapName=cluster-info-hcp-c1-2 \
  --results-dir "${RESULTS_DIR}" \
  --from 'INGRESS_DOMAIN=' \
  --to '# Generate summary' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract kubeconfig for hosted cluster' 'Hosted cluster kubeconfig extracted'

assert_rc 0
# Verify HPA was looked up ONLY in istio-gateways-2, not istio-system
assert_called "get hpa istio-ingressgateway -n istio-gateways-2"
assert_not_called "get hpa istio-ingressgateway -n istio-system"

echo "✅ PASS: configmap_cell_hpa_isolated"

# Test case: route_defaults
# No params → Route with host: eic.apps.test.example, ConfigMap route-info-hcp-c1
echo ""
echo "Test: route_defaults"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
whoami*	0	system:serviceaccount:default:pipeline
get svc istio-ingressgateway -n istio-gateways	0
get ingresscontroller default -n openshift-ingress-operator -o jsonpath*	0	apps.test.example
get ingresscontroller default -n openshift-ingress-operator -o json*	0	{"status":{"domain":"apps.test.example"}}
apply -f -*	0	route.route.openshift.io/eic-https-route created\nconfigmap/route-info-hcp-c1 created
get route eic-https-route -n istio-gateways*	0	eic-https-route eic.apps.test.example
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

run_task ../../.tekton/tasks/hcp-create-eic-route-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --from 'GW_NS=' \
  --to 'EIC Route Setup Complete' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract' 'oc whoami'

assert_rc 0
# Check that the Route was created with correct host
ROUTE_FILE="${FAKE_OC_STDIN_DIR}/1.yaml"
assert_file_contains "${ROUTE_FILE}" "host: eic.apps.test.example"
# Check ConfigMap was created with route-info-hcp-c1
CONFIGMAP_FILE="${FAKE_OC_STDIN_DIR}/2.yaml"
assert_file_contains "${CONFIGMAP_FILE}" "name: route-info-hcp-c1"
assert_file_contains "${CONFIGMAP_FILE}" 'host: "eic.apps.test.example"'

echo "✅ PASS: route_defaults"

# Test case: route_cell2
# With gatewayNamespace=istio-gateways-2, hostPrefix=eic-2, routeConfigMapName=route-info-hcp-c1-2
# → Route in istio-gateways-2 with host: eic-2.apps.test.example, ConfigMap route-info-hcp-c1-2
echo ""
echo "Test: route_cell2"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
whoami*	0	system:serviceaccount:default:pipeline
get svc istio-ingressgateway -n istio-gateways-2	0
get ingresscontroller default -n openshift-ingress-operator -o jsonpath*	0	apps.test.example
get ingresscontroller default -n openshift-ingress-operator -o json*	0	{"status":{"domain":"apps.test.example"}}
apply -f -*	0	route.route.openshift.io/eic-https-route created\nconfigmap/route-info-hcp-c1-2 created
get route eic-https-route -n istio-gateways-2*	0	eic-https-route eic-2.apps.test.example
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

run_task ../../.tekton/tasks/hcp-create-eic-route-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param gatewayNamespace=istio-gateways-2 \
  --param hostPrefix=eic-2 \
  --param routeConfigMapName=route-info-hcp-c1-2 \
  --from 'GW_NS=' \
  --to 'EIC Route Setup Complete' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract' 'oc whoami'

assert_rc 0
# Check that the Route was created in istio-gateways-2 with correct host
ROUTE_FILE="${FAKE_OC_STDIN_DIR}/1.yaml"
assert_file_contains "${ROUTE_FILE}" "namespace: istio-gateways-2"
assert_file_contains "${ROUTE_FILE}" "host: eic-2.apps.test.example"
# Check ConfigMap was created with route-info-hcp-c1-2
CONFIGMAP_FILE="${FAKE_OC_STDIN_DIR}/2.yaml"
assert_file_contains "${CONFIGMAP_FILE}" "name: route-info-hcp-c1-2"
assert_file_contains "${CONFIGMAP_FILE}" 'host: "eic-2.apps.test.example"'

echo "✅ PASS: route_cell2"

# Test case: route_missing_gateway_fails
# With gatewayNamespace=istio-gateways-3 (absent) → non-zero, message names istio-gateways-3
echo ""
echo "Test: route_missing_gateway_fails"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
whoami*	0	system:serviceaccount:default:pipeline
get svc istio-ingressgateway -n istio-gateways-3*	1	Error from server (NotFound)
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

run_task ../../.tekton/tasks/hcp-create-eic-route-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param gatewayNamespace=istio-gateways-3 \
  --from 'GW_NS=' \
  --to 'EIC Route Setup Complete' \
  --drop '# Install' 'oc version --client' \
  --drop '# Configure hub cluster kubeconfig' 'fi' \
  --drop '# Extract' 'oc whoami'

# Verify the task failed
if [[ "${TASK_RC}" -eq 0 ]]; then
  echo "❌ FAIL: task should have failed when gateway namespace not found"
  exit 1
fi

# Verify the error message mentions istio-gateways-3
if ! echo "${TASK_OUT}" | grep -qF "istio-gateways-3"; then
  echo "❌ FAIL: error message should mention 'istio-gateways-3'"
  echo "Actual output:"
  echo "${TASK_OUT}"
  exit 1
fi

echo "✅ PASS: route_missing_gateway_fails"

echo ""
echo "✅ ALL TESTS PASSED"
