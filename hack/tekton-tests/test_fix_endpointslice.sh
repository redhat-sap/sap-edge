#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: hcp-fix-endpointslice gateway selection"
echo "============================================"

# Test case: defaults_selector
# No guestServiceNamespace param → uses only tenant-service-name selector
echo ""
echo "Test: defaults_selector"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

cat > "${FAKE_OC_RULES}" <<'EOF'
get svc -n clusters-c1 -l cluster.x-k8s.io/tenant-service-name=istio-ingressgateway -o jsonpath=\{.items\[0\].metadata.name\}	0	svc-gw1
get endpointslice -n clusters-c1 -l kubernetes.io/service-name=svc-gw1 -o json	0	{"items":[]}
EOF

export FAKE_OC_LOG FAKE_OC_RULES

run_task ../../.tekton/tasks/hcp-fix-endpointslice-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param guestServiceName=istio-ingressgateway \
  --drop '# Install required tools' 'oc version --client'

assert_rc 0
assert_called "get svc -n clusters-c1 -l cluster.x-k8s.io/tenant-service-name=istio-ingressgateway"

echo "✅ PASS: defaults_selector"

# Test case: namespace_selects_one_gateway
# guestServiceNamespace=istio-gateways-2 → adds tenant-service-namespace to selector
echo ""
echo "Test: namespace_selects_one_gateway"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

# Rules must be ordered most-specific-first (first matching glob wins).
# With namespace selector → svc-gw2; without namespace → svc-gw1 (regression path)
cat > "${FAKE_OC_RULES}" <<'EOF'
get svc -n clusters-c1 -l cluster.x-k8s.io/tenant-service-name=istio-ingressgateway,cluster.x-k8s.io/tenant-service-namespace=istio-gateways-2 -o jsonpath=\{.items\[0\].metadata.name\}	0	svc-gw2
get svc -n clusters-c1 -l cluster.x-k8s.io/tenant-service-name=istio-ingressgateway -o jsonpath=\{.items\[0\].metadata.name\}	0	svc-gw1
get endpointslice -n clusters-c1 -l kubernetes.io/service-name=svc-gw2 -o json	0	{"items":[{"metadata":{"name":"slice-gw2"},"endpoints":[{"addresses":["10.0.0.1","10.0.0.2"]}]}]}
get endpointslice slice-gw2 -n clusters-c1 -o json	0	{"metadata":{"name":"slice-gw2"},"endpoints":[{"addresses":["10.0.0.1","10.0.0.2"]}]}
patch endpointslice slice-gw2 -n clusters-c1*	0	patched
get endpointslice -n clusters-c1 -l kubernetes.io/service-name=svc-gw1 -o json	0	{"items":[{"metadata":{"name":"slice-gw1"},"endpoints":[{"addresses":["10.0.1.1","10.0.1.2"]}]}]}
get endpointslice slice-gw1 -n clusters-c1 -o json	0	{"metadata":{"name":"slice-gw1"},"endpoints":[{"addresses":["10.0.1.1","10.0.1.2"]}]}
patch endpointslice slice-gw1 -n clusters-c1*	0	patched
EOF

export FAKE_OC_LOG FAKE_OC_RULES

run_task ../../.tekton/tasks/hcp-fix-endpointslice-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param guestServiceName=istio-ingressgateway \
  --param guestServiceNamespace=istio-gateways-2 \
  --drop '# Install required tools' 'oc version --client'

assert_rc 0
# Assert the selector includes the tenant-service-namespace label
assert_called "get svc -n clusters-c1 -l cluster.x-k8s.io/tenant-service-name=istio-ingressgateway,cluster.x-k8s.io/tenant-service-namespace=istio-gateways-2"
# Assert endpointslice operations reference svc-gw2
assert_called "get endpointslice -n clusters-c1 -l kubernetes.io/service-name=svc-gw2"
# Assert no calls reference svc-gw1
assert_not_called "svc-gw1"

echo "✅ PASS: namespace_selects_one_gateway"

echo ""
echo "============================================"
echo "✅ ALL TESTS PASSED"
echo "============================================"
