#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-sap-browser-access task"
echo "============================================"

TASK=../../.tekton/tasks/roks-sap-browser-access-task.yaml
CLUSTER=redhat-roks-eic-pr7
EDGE_NODE_ID="a1b2c3d4-e5f6-7890-1234-567890abcdef"

# Fresh workspace and fake oc for the task
setup() {
  WS=$(tmp_dir)
  printf 'apiVersion: v1\nkind: Config\n' > "${WS}/kubeconfig"

  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

  RESULTS_DIR=$(tmp_dir)

  export CLUSTER_NAME="${CLUSTER}"
  export RUNNER_SERVICE_ACCOUNT="roks-sap-browser-runner"
}

# Captured manifest (FAKE_OC_STDIN_DIR) of the object with this metadata.name
captured_manifest() {
  local FILE
  for FILE in "${FAKE_OC_STDIN_DIR}"/*.yaml; do
    [[ -f "${FILE}" ]] || continue
    if grep -qE "^  name: $1\$" "${FILE}"; then
      echo "${FILE}"
      return 0
    fi
  done
  return 1
}

run_browser_access() {
  printf '%s\t%s\t%s\n' \
    '--kubeconfig */kubeconfig get ns edgelm --ignore-not-found -o json' 0 "{\"metadata\":{\"labels\":{\"edgelm.sap.com/edge-node-id\":\"${EDGE_NODE_ID}\"}}}" \
    > "${FAKE_OC_RULES}"

  TASK_CWD="${WS}" run_task "${TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --param runnerServiceAccount="${RUNNER_SERVICE_ACCOUNT}" \
    --workspace-dir source="${WS}" \
    --results-dir "${RESULTS_DIR}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

expect_success() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
    fail "expected exit 0, got ${TASK_RC}"
  fi
}

# Test case: env_wiring
echo ""
echo "Test: env_wiring"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")

errors = []
if task["metadata"]["name"] != "roks-sap-browser-access":
    errors.append("task must be named roks-sap-browser-access")
params = {p["name"]: p.get("default") for p in task["spec"]["params"]}
expected_defaults = {
    "clusterName": None,
    "runnerServiceAccount": "roks-sap-browser-runner",
}
if params != expected_defaults:
    errors.append(f"params/defaults differ: {params}")

if [w["name"] for w in task["spec"]["workspaces"]] != ["source"]:
    errors.append("expected exactly the workspace 'source'")
if [r["name"] for r in task["spec"].get("results", [])] != ["clusterEdgeNodeId"]:
    errors.append("expected exactly the result 'clusterEdgeNodeId'")

steps = task["spec"]["steps"]
if len(steps) != 1:
    errors.append("expected exactly one step")
step = steps[0]
env = {e["name"]: e for e in step.get("env", [])}
expected_values = {
    "CLUSTER_NAME": "$(params.clusterName)",
    "RUNNER_SERVICE_ACCOUNT": "$(params.runnerServiceAccount)",
}
for name, value in expected_values.items():
    if env.get(name, {}).get("value") != value:
        errors.append(f"env {name} should be {value}, got {env.get(name)}")
if any("valueFrom" in e for e in env.values()):
    errors.append("no Secret should be read into the env")
if step.get("workingDir") != "$(workspaces.source.path)":
    errors.append("workingDir must be the source workspace")
script = step["script"]
if "set -x" in script:
    errors.append("script must not use set -x")
if "set -euo pipefail" not in script:
    errors.append("script must use set -euo pipefail")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: env_wiring"

# Test case: role_names_only_this_runs_secrets
echo ""
echo "Test: role_names_only_this_runs_secrets"
echo "--------------------------------------------"
setup
run_browser_access
expect_success

ROLE=$(captured_manifest "roks-sap-browser-${CLUSTER}") || { cat "${FAKE_OC_LOG}"; fail "Role roks-sap-browser-${CLUSTER} not applied"; }
assert_file_contains "${ROLE}" "^kind: Role$"
assert_file_contains "${ROLE}" "^  name: roks-sap-browser-${CLUSTER}$"

# Check the Role has exactly one rule with verb get and the three secret names
python3 -I - "${ROLE}" "${CLUSTER}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    role = yaml.safe_load(f)
cluster = sys.argv[2]

errors = []
rules = role.get("rules", [])
if len(rules) != 1:
    errors.append(f"expected exactly one rule, got {len(rules)}")
    sys.exit(1)

rule = rules[0]
if rule.get("apiGroups") != [""]:
    errors.append(f"apiGroups should be [''], got {rule.get('apiGroups')}")
if rule.get("resources") != ["secrets"]:
    errors.append(f"resources should be ['secrets'], got {rule.get('resources')}")
if rule.get("verbs") != ["get"]:
    errors.append(f"verbs should be ['get'], got {rule.get('verbs')}")

expected_names = sorted([
    f"eic-credentials-roks-{cluster}",
    f"eic-registry-roks-{cluster}",
    f"edgelm-kubeconfig-generated-{cluster}",
])
actual_names = sorted(rule.get("resourceNames", []))
if actual_names != expected_names:
    errors.append(f"resourceNames should be {expected_names}, got {actual_names}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: role_names_only_this_runs_secrets"

# Test case: binding_targets_runner_sa
echo ""
echo "Test: binding_targets_runner_sa"
echo "--------------------------------------------"
setup
run_browser_access
expect_success

# The RoleBinding and Role have the same name, so we need to find both
BINDING_FILE=""
for FILE in "${FAKE_OC_STDIN_DIR}"/*.yaml; do
  [[ -f "${FILE}" ]] || continue
  if grep -qE "^  name: roks-sap-browser-${CLUSTER}\$" "${FILE}"; then
    if grep -qE "^kind: RoleBinding\$" "${FILE}"; then
      BINDING_FILE="${FILE}"
      break
    fi
  fi
done

[[ -n "${BINDING_FILE}" ]] || { cat "${FAKE_OC_LOG}"; fail "RoleBinding roks-sap-browser-${CLUSTER} not applied"; }

python3 -I - "${BINDING_FILE}" "${RUNNER_SERVICE_ACCOUNT}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    binding = yaml.safe_load(f)
sa_name = sys.argv[2]

errors = []
if binding.get("kind") != "RoleBinding":
    errors.append(f"kind should be RoleBinding, got {binding.get('kind')}")

roleRef = binding.get("roleRef", {})
if roleRef.get("apiGroup") != "rbac.authorization.k8s.io":
    errors.append(f"roleRef.apiGroup should be rbac.authorization.k8s.io, got {roleRef.get('apiGroup')}")
if roleRef.get("kind") != "Role":
    errors.append(f"roleRef.kind should be Role, got {roleRef.get('kind')}")
if not roleRef.get("name", "").startswith("roks-sap-browser-"):
    errors.append(f"roleRef.name should start with roks-sap-browser-, got {roleRef.get('name')}")

subjects = binding.get("subjects", [])
if len(subjects) != 1:
    errors.append(f"expected exactly one subject, got {len(subjects)}")
else:
    subject = subjects[0]
    if subject.get("kind") != "ServiceAccount":
        errors.append(f"subject.kind should be ServiceAccount, got {subject.get('kind')}")
    if subject.get("name") != sa_name:
        errors.append(f"subject.name should be {sa_name}, got {subject.get('name')}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY

assert_called "^apply -f -$"
echo "✅ PASS: binding_targets_runner_sa"

# Test case: edge_node_id_result
echo ""
echo "Test: edge_node_id_result"
echo "--------------------------------------------"
setup
run_browser_access
expect_success

# Check that the task queries the ROKS cluster for the edge node ID
assert_called "^--kubeconfig ${WS}/kubeconfig get ns edgelm --ignore-not-found -o json$"

# Check the result file contains the edge node ID
RESULT=$(cat "${RESULTS_DIR}/clusterEdgeNodeId")
[[ "${RESULT}" == "${EDGE_NODE_ID}" ]] || fail "clusterEdgeNodeId result should be '${EDGE_NODE_ID}', got '${RESULT}'"
echo "✅ PASS: edge_node_id_result"

# Test case: edge_node_id_empty_when_absent
echo ""
echo "Test: edge_node_id_empty_when_absent"
echo "--------------------------------------------"
# Namespace missing (--ignore-not-found returns rc 0 with empty output)
setup
printf '%s\t%s\t%s\n' \
  '--kubeconfig */kubeconfig get ns edgelm --ignore-not-found -o json' 0 '' \
  > "${FAKE_OC_RULES}"
TASK_CWD="${WS}" run_task "${TASK}" \
  --param clusterName="${CLUSTER_NAME}" \
  --param runnerServiceAccount="${RUNNER_SERVICE_ACCOUNT}" \
  --workspace-dir source="${WS}" \
  --results-dir "${RESULTS_DIR}" \
  --drop '# Install tools' 'echo "✅ Tools installed"'
expect_success
RESULT=$(cat "${RESULTS_DIR}/clusterEdgeNodeId")
[[ "${RESULT}" == "" ]] || fail "clusterEdgeNodeId result should be empty when namespace is missing, got '${RESULT}'"

# Label missing
setup
printf '%s\t%s\t%s\n' \
  '--kubeconfig */kubeconfig get ns edgelm --ignore-not-found -o json' 0 '{"metadata":{"labels":{}}}' \
  > "${FAKE_OC_RULES}"
TASK_CWD="${WS}" run_task "${TASK}" \
  --param clusterName="${CLUSTER_NAME}" \
  --param runnerServiceAccount="${RUNNER_SERVICE_ACCOUNT}" \
  --workspace-dir source="${WS}" \
  --results-dir "${RESULTS_DIR}" \
  --drop '# Install tools' 'echo "✅ Tools installed"'
expect_success
RESULT=$(cat "${RESULTS_DIR}/clusterEdgeNodeId")
[[ "${RESULT}" == "" ]] || fail "clusterEdgeNodeId result should be empty when label is missing, got '${RESULT}'"

echo "✅ PASS: edge_node_id_empty_when_absent"

# Test case: edge_node_id_unknown_on_read_error
echo ""
echo "Test: edge_node_id_unknown_on_read_error"
echo "--------------------------------------------"
setup
printf '%s\t%s\t%s\n' \
  '--kubeconfig */kubeconfig get ns edgelm --ignore-not-found -o json' 1 'Error from server (Unauthorized): namespaces "edgelm" is forbidden: User "system:serviceaccount:default:cluster-admin-sa" cannot get resource "namespaces" in API group "" in the namespace "edgelm"' \
  > "${FAKE_OC_RULES}"
TASK_CWD="${WS}" run_task "${TASK}" \
  --param clusterName="${CLUSTER_NAME}" \
  --param runnerServiceAccount="${RUNNER_SERVICE_ACCOUNT}" \
  --workspace-dir source="${WS}" \
  --results-dir "${RESULTS_DIR}" \
  --drop '# Install tools' 'echo "✅ Tools installed"'
expect_success
RESULT=$(cat "${RESULTS_DIR}/clusterEdgeNodeId")
[[ "${RESULT}" == "unknown" ]] || fail "clusterEdgeNodeId result should be 'unknown' on read error, got '${RESULT}'"
grep -q "⚠️.*Could not read namespace edgelm" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "warning not printed on read error"; }
grep -q "Unauthorized" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error category not printed"; }
echo "✅ PASS: edge_node_id_unknown_on_read_error"

# Test case: role_apply_failure_does_not_fail_task
echo ""
echo "Test: role_apply_failure_does_not_fail_task"
echo "--------------------------------------------"
setup
printf '%s\t%s\t%s\n' \
  '--kubeconfig */kubeconfig get ns edgelm --ignore-not-found -o json' 0 '' \
  'apply -f -' 1 'Error from server (Forbidden): error when creating "STDIN": roles.rbac.authorization.k8s.io "roks-sap-browser-redhat-roks-eic-pr7" is forbidden: user "system:serviceaccount:default:pipeline" (groups=["system:serviceaccounts" "system:serviceaccounts:default" "system:authenticated"]) is attempting to grant RBAC permissions not currently held' \
  > "${FAKE_OC_RULES}"
TASK_CWD="${WS}" run_task "${TASK}" \
  --param clusterName="${CLUSTER_NAME}" \
  --param runnerServiceAccount="${RUNNER_SERVICE_ACCOUNT}" \
  --workspace-dir source="${WS}" \
  --results-dir "${RESULTS_DIR}" \
  --drop '# Install tools' 'echo "✅ Tools installed"'
expect_success
grep -q "❌.*Failed to create.*the browser will not be able to read this run's Secrets" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error message not printed on RBAC apply failure"; }
grep -q "Kubernetes RBAC escalation check" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "escalation check explanation not printed"; }
echo "✅ PASS: role_apply_failure_does_not_fail_task"

echo ""
echo "============================================"
echo "✅ All roks-sap-browser-access tests passed"
echo "============================================"
