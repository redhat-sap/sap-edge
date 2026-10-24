#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: Generate SA-Based Kubeconfig"
echo "============================================"

# Test case: defaults
# No elmNamespace or generatedSecretName params → uses edgelm namespace and default secret name
echo ""
echo "Test: defaults"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

# Generate base64 fixtures at runtime to avoid cspell issues
TOKEN_B64=$(printf 'token123' | base64)
CA_CERT_B64=$(printf 'caCert' | base64)

# Set up fake oc rules
cat > "${FAKE_OC_RULES}" <<EOF
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get sa edgelm -n edgelm*	1
create sa edgelm -n edgelm*	0	serviceaccount/edgelm created
apply -n edgelm -f -*	0	secret/edgelm-kubeconfig-token configured
get secret edgelm-kubeconfig-token -n edgelm -o jsonpath=*	0	${TOKEN_B64}
get secret edgelm-kubeconfig-token -n edgelm*	0	{"data":{"token":"${TOKEN_B64}"}}
config view --minify*	0	{"clusters":[{"cluster":{"server":"https://api.example.com:6443"},"name":"c1"}]}
config view --raw --minify*	0	{"clusters":[{"cluster":{"certificate-authority-data":"${CA_CERT_B64}","server":"https://api.example.com:6443"},"name":"c1"}]}
--kubeconfig=* auth can-i list pods -n edgelm*	0	yes
--kubeconfig=* get namespaces*	0	edgelm
apply -f -*	0	secret/edgelm-kubeconfig-generated-c1 configured
get rolebinding rb-edgelm-manage -n edgelm*	0	{"subjects":[{"kind":"ServiceAccount","name":"edgelm","namespace":"edgelm"}]}
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

# shellcheck disable=SC2016
run_task ../../.tekton/tasks/ossm3-generate-sa-based-kubeconfig-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR}" \
  --drop '# Install required tools' 'oc version --client' \
  --from '# --- 1. Determine SA name from RoleBinding'

assert_rc 0

# Verify SA creation in edgelm namespace
if ! grep -qF "create sa edgelm -n edgelm" "${FAKE_OC_LOG}"; then
  echo "❌ FAIL: Should create SA edgelm in namespace edgelm"
  cat "${FAKE_OC_LOG}"
  exit 1
fi

# Verify workspace file is edgelm-kubeconfig
if [[ ! -f "${WORKSPACE_DIR}/edgelm-kubeconfig" ]]; then
  echo "❌ FAIL: Workspace file should be edgelm-kubeconfig"
  ls -la "${WORKSPACE_DIR}"
  exit 1
fi

# Verify Secret name is edgelm-kubeconfig-generated-c1
SECRET_YAML=$(find "${FAKE_OC_STDIN_DIR}" -name "*.yaml" -exec grep -l "edgelm-kubeconfig-generated-c1" {} \; | head -1)
if [[ -z "${SECRET_YAML}" ]]; then
  echo "❌ FAIL: Secret should be named edgelm-kubeconfig-generated-c1"
  find "${FAKE_OC_STDIN_DIR}" -name "*.yaml" -exec cat {} \;
  exit 1
fi

# Verify result mentions namespace and SA
RESULT=$(cat "${RESULTS_DIR}/kubeconfig-info")
if [[ "${RESULT}" != *"edgelm"* ]]; then
  echo "❌ FAIL: Result should mention edgelm namespace/SA"
  echo "Actual: ${RESULT}"
  exit 1
fi

echo "✅ PASS: defaults"

# Test case: stack2
# elmNamespace=edgelm-2, generatedSecretName=edgelm-kubeconfig-generated-c1-2
# RoleBinding returns SA edgelm → creates edgelm SA in edgelm-2 namespace
echo ""
echo "Test: stack2"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

# Generate base64 fixtures at runtime to avoid cspell issues
TOKEN_B64=$(printf 'token222' | base64)
CA_CERT_B64=$(printf 'caCert' | base64)

# Set up fake oc rules
cat > "${FAKE_OC_RULES}" <<EOF
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get rolebinding rb-edgelm-manage -n edgelm-2*	0	{"subjects":[{"kind":"ServiceAccount","name":"edgelm","namespace":"edgelm-2"}]}
get sa edgelm -n edgelm-2*	1
create sa edgelm -n edgelm-2*	0	serviceaccount/edgelm created
apply -n edgelm-2 -f -*	0	secret/edgelm-kubeconfig-token configured
get secret edgelm-kubeconfig-token -n edgelm-2 -o jsonpath=*	0	${TOKEN_B64}
get secret edgelm-kubeconfig-token -n edgelm-2*	0	{"data":{"token":"${TOKEN_B64}"}}
config view --minify*	0	{"clusters":[{"cluster":{"server":"https://api.example.com:6443"},"name":"c1"}]}
config view --raw --minify*	0	{"clusters":[{"cluster":{"certificate-authority-data":"${CA_CERT_B64}","server":"https://api.example.com:6443"},"name":"c1"}]}
--kubeconfig=* auth can-i list pods -n edgelm-2*	0	yes
--kubeconfig=* get namespaces*	0	edgelm-2
apply -f -*	0	secret/edgelm-kubeconfig-generated-c1-2 configured
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

# shellcheck disable=SC2016
run_task ../../.tekton/tasks/ossm3-generate-sa-based-kubeconfig-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param elmNamespace=edgelm-2 \
  --param generatedSecretName=edgelm-kubeconfig-generated-c1-2 \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR}" \
  --drop '# Install required tools' 'oc version --client' \
  --from '# --- 1. Determine SA name from RoleBinding'

assert_rc 0

# Verify SA creation in edgelm-2 namespace
if ! grep -qF "create sa edgelm -n edgelm-2" "${FAKE_OC_LOG}"; then
  echo "❌ FAIL: Should create SA edgelm in namespace edgelm-2"
  cat "${FAKE_OC_LOG}"
  exit 1
fi

# Verify token secret creation in edgelm-2 namespace
if ! grep -qE "apply.*-n edgelm-2.*-f -" "${FAKE_OC_LOG}"; then
  echo "❌ FAIL: Should create token secret in namespace edgelm-2"
  cat "${FAKE_OC_LOG}"
  exit 1
fi

# Verify workspace file is edgelm-2-kubeconfig
if [[ ! -f "${WORKSPACE_DIR}/edgelm-2-kubeconfig" ]]; then
  echo "❌ FAIL: Workspace file should be edgelm-2-kubeconfig"
  ls -la "${WORKSPACE_DIR}"
  exit 1
fi

# Verify Secret name is edgelm-kubeconfig-generated-c1-2
SECRET_YAML=$(find "${FAKE_OC_STDIN_DIR}" -name "*.yaml" -exec grep -l "edgelm-kubeconfig-generated-c1-2" {} \; | head -1)
if [[ -z "${SECRET_YAML}" ]]; then
  echo "❌ FAIL: Secret should be named edgelm-kubeconfig-generated-c1-2"
  find "${FAKE_OC_STDIN_DIR}" -name "*.yaml" -exec cat {} \;
  exit 1
fi

# Verify result mentions edgelm-2 namespace
RESULT=$(cat "${RESULTS_DIR}/kubeconfig-info")
if [[ "${RESULT}" != *"edgelm-2"* ]]; then
  echo "❌ FAIL: Result should mention edgelm-2 namespace"
  echo "Actual: ${RESULT}"
  exit 1
fi

echo "✅ PASS: stack2"

# Test case: two_stacks_distinct_outputs
# Run both stack1 (defaults) and stack2 into same workspace → files and Secrets must not collide
echo ""
echo "Test: two_stacks_distinct_outputs"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
FAKE_OC_STDIN_DIR=$(tmp_dir)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR_1=$(tmp_dir)
RESULTS_DIR_2=$(tmp_dir)

# Generate base64 fixtures at runtime to avoid cspell issues
TOKEN1_B64=$(printf 'token111' | base64)
TOKEN2_B64=$(printf 'token222' | base64)
CA_CERT_B64=$(printf 'caCert' | base64)

# Set up fake oc rules (combined for both runs)
cat > "${FAKE_OC_RULES}" <<EOF
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get rolebinding rb-edgelm-manage -n edgelm-2*	0	{"subjects":[{"kind":"ServiceAccount","name":"edgelm","namespace":"edgelm-2"}]}
get rolebinding rb-edgelm-manage -n edgelm*	0	{"subjects":[{"kind":"ServiceAccount","name":"edgelm","namespace":"edgelm"}]}
get sa edgelm -n edgelm-2*	1
get sa edgelm -n edgelm*	1
create sa edgelm -n edgelm-2*	0	serviceaccount/edgelm created
create sa edgelm -n edgelm*	0	serviceaccount/edgelm created
apply -n edgelm-2 -f -*	0	secret/edgelm-kubeconfig-token configured
apply -n edgelm -f -*	0	secret/edgelm-kubeconfig-token configured
get secret edgelm-kubeconfig-token -n edgelm-2 -o jsonpath=*	0	${TOKEN2_B64}
get secret edgelm-kubeconfig-token -n edgelm-2*	0	{"data":{"token":"${TOKEN2_B64}"}}
get secret edgelm-kubeconfig-token -n edgelm -o jsonpath=*	0	${TOKEN1_B64}
get secret edgelm-kubeconfig-token -n edgelm*	0	{"data":{"token":"${TOKEN1_B64}"}}
config view --minify*	0	{"clusters":[{"cluster":{"server":"https://api.example.com:6443"},"name":"c1"}]}
config view --raw --minify*	0	{"clusters":[{"cluster":{"certificate-authority-data":"${CA_CERT_B64}","server":"https://api.example.com:6443"},"name":"c1"}]}
--kubeconfig=* auth can-i list pods*	0	yes
--kubeconfig=* get namespaces*	0	edgelm
apply -f -*	0	secret applied
EOF

export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

# Run stack1 (defaults)
# shellcheck disable=SC2016
run_task ../../.tekton/tasks/ossm3-generate-sa-based-kubeconfig-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR_1}" \
  --drop '# Install required tools' 'oc version --client' \
  --from '# --- 1. Determine SA name from RoleBinding'

assert_rc 0

# Verify stack1 workspace file exists
if [[ ! -f "${WORKSPACE_DIR}/edgelm-kubeconfig" ]]; then
  echo "❌ FAIL: Stack1 workspace file edgelm-kubeconfig not found"
  ls -la "${WORKSPACE_DIR}"
  exit 1
fi

STACK1_SIZE=$(wc -c < "${WORKSPACE_DIR}/edgelm-kubeconfig")

# Run stack2 (edgelm-2)
# shellcheck disable=SC2016
run_task ../../.tekton/tasks/ossm3-generate-sa-based-kubeconfig-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param elmNamespace=edgelm-2 \
  --param generatedSecretName=edgelm-kubeconfig-generated-c1-2 \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR_2}" \
  --drop '# Install required tools' 'oc version --client' \
  --from '# --- 1. Determine SA name from RoleBinding'

assert_rc 0

# Verify both workspace files exist
if [[ ! -f "${WORKSPACE_DIR}/edgelm-kubeconfig" ]]; then
  echo "❌ FAIL: Stack1 workspace file edgelm-kubeconfig was overwritten"
  ls -la "${WORKSPACE_DIR}"
  exit 1
fi

if [[ ! -f "${WORKSPACE_DIR}/edgelm-2-kubeconfig" ]]; then
  echo "❌ FAIL: Stack2 workspace file edgelm-2-kubeconfig not found"
  ls -la "${WORKSPACE_DIR}"
  exit 1
fi

# Verify stack1 file wasn't overwritten by checking size
STACK1_SIZE_AFTER=$(wc -c < "${WORKSPACE_DIR}/edgelm-kubeconfig")
if [[ "${STACK1_SIZE}" -ne "${STACK1_SIZE_AFTER}" ]]; then
  echo "❌ FAIL: Stack1 workspace file was modified by stack2"
  exit 1
fi

# Verify each stack stored its own kubeconfig under its own Secret name:
# exactly one captured Secret manifest per exact name, and its kubeconfig
# carries that stack's token (stack 1: token111, stack 2: token222).
for PAIR in "edgelm-kubeconfig-generated-c1:token111" "edgelm-kubeconfig-generated-c1-2:token222"; do
  NAME="${PAIR%%:*}"
  TOKEN="${PAIR##*:}"
  MATCHES=$(grep -lE "^[[:space:]]*name: ${NAME}[[:space:]]*$" "${FAKE_OC_STDIN_DIR}"/*.yaml || true)
  COUNT=$(grep -c . <<< "${MATCHES}" || true)
  if [[ "${COUNT}" -ne 1 ]]; then
    cat "${FAKE_OC_STDIN_DIR}"/*.yaml
    fail "expected exactly one captured Secret named ${NAME}, found ${COUNT}"
  fi
  KUBECONFIG_B64=$(sed -nE 's/^[[:space:]]*kubeconfig:[[:space:]]*//p' "${MATCHES}")
  [[ -n "${KUBECONFIG_B64}" ]] || fail "Secret ${NAME} has no kubeconfig data"
  DECODED=$(printf '%s' "${KUBECONFIG_B64}" | base64 --decode)
  if [[ "${DECODED}" != *"token: ${TOKEN}"* ]]; then
    echo "${DECODED}"
    fail "Secret ${NAME} does not carry its own stack's token (${TOKEN})"
  fi
done

echo "✅ PASS: two_stacks_distinct_outputs"

echo ""
echo "============================================"
echo "✅ All tests passed!"
echo "============================================"
