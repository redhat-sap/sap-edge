#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0
# cspell:words benv findall PWDEBUG repr splitlines

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: hcp-sap-browser-access and hcp-sap-browser tasks"
echo "============================================"

TASK=../../.tekton/tasks/hcp-sap-browser-access-task.yaml
BROWSER_TASK=../../.tekton/tasks/hcp-sap-browser-task.yaml
RUNNER_RBAC=../../hack/sap-browser/hcp-runner-rbac.yaml
CLUSTER=hcp-eic-pr42
HUB=eli
EDGE_NODE_ID="a1b2c3d4-e5f6-7890-1234-567890abcdef"
RUNNER_SA=hcp-sap-browser-runner

[[ -f "${TASK}" ]] || fail "${TASK} not found"

# Fresh workspace and fake oc for the access task
setup() {
  WS=$(tmp_dir)
  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDERR_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDERR_RULES FAKE_OC_STDIN_DIR
  RESULTS_DIR=$(tmp_dir)
  MODE=auto
  CELL_COUNT=""
  HUB_SECRET="${HUB}-kubeconfig"
}

HUB_KUBECONFIG_B64=$(printf 'apiVersion: v1\nkind: Config\n# hub\n' | base64 | tr -d '\n')
HOSTED_KUBECONFIG_B64=$(printf 'apiVersion: v1\nkind: Config\n# hosted\n' | base64 | tr -d '\n')

# Rules for a healthy run through the remote hub: hub kubeconfig from the
# pipeline namespace, the hosted admin kubeconfig through the hub, the edgelm
# namespace through the hosted kubeconfig. $1: output of the namespace read.
write_rules() {
  printf '%s\t%s\t%s\n' \
    "get secret ${HUB}-kubeconfig -o jsonpath={.data.kubeconfig}" 0 "${HUB_KUBECONFIG_B64}" \
    "--kubeconfig */hub-kubeconfig get secret ${CLUSTER}-admin-kubeconfig -n clusters -o jsonpath={.data.kubeconfig}" 0 "${HOSTED_KUBECONFIG_B64}" \
    "get secret ${CLUSTER}-admin-kubeconfig -n clusters -o jsonpath={.data.kubeconfig}" 0 "${HOSTED_KUBECONFIG_B64}" \
    "--kubeconfig */hosted-kubeconfig get ns edgelm --ignore-not-found -o json" 0 "$1" \
    > "${FAKE_OC_RULES}"
}

# The step env (extract_task_script.py substitutes params in the script only)
run_access() {
  export HOSTED_CLUSTER_NAME="${CLUSTER}" HOSTED_CLUSTER_NAMESPACE=clusters \
    HUB_KUBECONFIG_SECRET_NAME="${HUB_SECRET}" HUB_CLUSTER_NAME="${HUB}" \
    SAP_BROWSER_MODE="${MODE}" CELL_COUNT
  TASK_CWD="${WS}" run_task "${TASK}" \
    --param hostedClusterName="${CLUSTER}" \
    --param hostedClusterNamespace=clusters \
    --param hubKubeconfigSecretName="${HUB_SECRET}" \
    --param hubClusterName="${HUB}" \
    --param mode="${MODE}" \
    --param cellCount="${CELL_COUNT}" \
    --workspace-dir source="${WS}" \
    --results-dir "${RESULTS_DIR}" \
    "$@"
}

run_access_no_tools() {
  run_access --drop '# Install tools' 'echo "✅ Tools installed"'
}

expect_success() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
    fail "expected exit 0, got ${TASK_RC}"
  fi
}

result() {
  cat "${RESULTS_DIR}/$1" 2>/dev/null || true
}

# Captured manifest (FAKE_OC_STDIN_DIR) of kind $1 named $2
captured_manifest() {
  local FILE
  for FILE in "${FAKE_OC_STDIN_DIR}"/*.yaml; do
    [[ -f "${FILE}" ]] || continue
    if grep -qE "^kind: $1\$" "${FILE}" && grep -qE "^  name: $2\$" "${FILE}"; then
      echo "${FILE}"
      return 0
    fi
  done
  return 1
}

# Test case: access_task_definition
echo ""
echo "Test: access_task_definition"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")

errors = []
MISSING = object()
if task["metadata"]["name"] != "hcp-sap-browser-access":
    errors.append("task must be named hcp-sap-browser-access")
params = {p["name"]: p.get("default", MISSING) for p in task["spec"]["params"]}
expected = {
    "hostedClusterName": MISSING,
    "hostedClusterNamespace": "clusters",
    "hubKubeconfigSecretName": "",
    "hubClusterName": MISSING,
    "mode": MISSING,
    "cellCount": "",
}
if params.keys() != expected.keys():
    errors.append(f"params differ: {sorted(params)} vs {sorted(expected)}")
for name, default in expected.items():
    if name in params and params[name] is not default and params[name] != default:
        errors.append(f"param {name}: default should be {'<none>' if default is MISSING else repr(default)}, got {params[name]!r}")
if [r["name"] for r in task["spec"].get("results", [])] != ["clusterEdgeNodeId", "proxyConfigured"]:
    errors.append("expected exactly the results clusterEdgeNodeId and proxyConfigured")
if [w["name"] for w in task["spec"].get("workspaces", [])] != ["source"]:
    errors.append("expected exactly the workspace 'source' (for .kubeconfig-rewrite.sh)")
steps = task["spec"]["steps"]
if len(steps) != 1:
    errors.append("expected exactly one step")
step = steps[0]
env = {e["name"]: e for e in step.get("env", [])}
want_env = {
    "HOSTED_CLUSTER_NAME": "$(params.hostedClusterName)",
    "HOSTED_CLUSTER_NAMESPACE": "$(params.hostedClusterNamespace)",
    "HUB_KUBECONFIG_SECRET_NAME": "$(params.hubKubeconfigSecretName)",
    "HUB_CLUSTER_NAME": "$(params.hubClusterName)",
    "SAP_BROWSER_MODE": "$(params.mode)",
    "CELL_COUNT": "$(params.cellCount)",
}
for name, value in want_env.items():
    if env.get(name) != {"name": name, "value": value}:
        errors.append(f"env {name} should be {value}, got {env.get(name)}")
if set(env) != set(want_env):
    errors.append(f"unexpected env: {sorted(set(env) - set(want_env))}")
script = step["script"]
if "set -euo pipefail" not in script or "set -x" in script:
    errors.append("script must use set -euo pipefail and no set -x")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: access_task_definition"

# Test case: disabled_does_nothing
# The pipeline runs the access task without a `when` (the browser task consumes
# its results): with mode disabled it installs nothing and calls no oc.
echo ""
echo "Test: disabled_does_nothing"
echo "--------------------------------------------"
setup
MODE=disabled
FAKE_TOOLS_DIR=$(tmp_dir)
FAKE_TOOLS_LOG=$(tmp_file)
export FAKE_TOOLS_LOG
for TOOL in dnf curl tar; do
  cat > "${FAKE_TOOLS_DIR}/${TOOL}" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "${FAKE_TOOLS_LOG}"
exit 1
EOF
  chmod +x "${FAKE_TOOLS_DIR}/${TOOL}"
done
# No --drop: the install section must not be reached either
PATH="${FAKE_TOOLS_DIR}:${PATH}" run_access
expect_success
[[ -f "${RESULTS_DIR}/clusterEdgeNodeId" ]] || fail "clusterEdgeNodeId result not written"
[[ -z "$(result clusterEdgeNodeId)" ]] || fail "clusterEdgeNodeId should be empty, got '$(result clusterEdgeNodeId)'"
[[ "$(result proxyConfigured)" == "false" ]] || fail "proxyConfigured should be 'false', got '$(result proxyConfigured)'"
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "oc must not be called: $(cat "${FAKE_OC_LOG}")"
[[ ! -s "${FAKE_TOOLS_LOG}" ]] || fail "no tools may be installed: $(cat "${FAKE_TOOLS_LOG}")"
grep -qF "browser automation disabled; nothing to do" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "disabled message not printed"; }
echo "✅ PASS: disabled_does_nothing"

# Check the per-run Role and RoleBinding: one get rule on exactly the names given
check_role() {
  local ROLE BINDING
  ROLE=$(captured_manifest Role "hcp-sap-browser-${CLUSTER}") || { cat "${FAKE_OC_LOG}"; fail "Role hcp-sap-browser-${CLUSTER} not applied"; }
  BINDING=$(captured_manifest RoleBinding "hcp-sap-browser-${CLUSTER}") || { cat "${FAKE_OC_LOG}"; fail "RoleBinding hcp-sap-browser-${CLUSTER} not applied"; }
  python3 -I - "${ROLE}" "${BINDING}" "${CLUSTER}" "${RUNNER_SA}" "$@" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    role = yaml.safe_load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    binding = yaml.safe_load(f)
cluster, runner, names = sys.argv[3], sys.argv[4], sys.argv[5:]

errors = []
want_rules = [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"], "resourceNames": names}]
if role.get("rules") != want_rules:
    errors.append(f"Role rules should be {want_rules}, got {role.get('rules')}")
want_binding = {
    "apiVersion": "rbac.authorization.k8s.io/v1",
    "kind": "RoleBinding",
    "metadata": {"name": f"hcp-sap-browser-{cluster}"},
    "subjects": [{"kind": "ServiceAccount", "name": runner}],
    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": f"hcp-sap-browser-{cluster}"},
}
if binding != want_binding:
    errors.append(f"RoleBinding should be {want_binding}, got {binding}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
}

# Test case: role_names_this_runs_secrets
echo ""
echo "Test: role_names_this_runs_secrets"
echo "--------------------------------------------"
# Single EIC (cellCount ''): the unsuffixed credentials Secret
setup
write_rules "{\"metadata\":{\"labels\":{\"edgelm.sap.com/edge-node-id\":\"${EDGE_NODE_ID}\"}}}"
run_access_no_tools
expect_success
check_role "edgelm-kubeconfig-generated-${CLUSTER}" "eic-credentials-hcp-${CLUSTER}" "${HUB}-quay-robot"
# Dedicated with two cells: one credentials Secret per cell
setup
CELL_COUNT=2
write_rules "{\"metadata\":{\"labels\":{\"edgelm.sap.com/edge-node-id\":\"${EDGE_NODE_ID}\"}}}"
run_access_no_tools
expect_success
check_role "edgelm-kubeconfig-generated-${CLUSTER}" "eic-credentials-hcp-${CLUSTER}-eic-1" "eic-credentials-hcp-${CLUSTER}-eic-2" "${HUB}-quay-robot"
# RBAC calls go to the pipeline cluster (in-cluster ServiceAccount), not the hub
assert_called "^apply -f -$"
assert_not_called "^--kubeconfig .* apply"
echo "✅ PASS: role_names_this_runs_secrets"

# Test case: invalid_inputs_fail
echo ""
echo "Test: invalid_inputs_fail"
echo "--------------------------------------------"
setup
CELL_COUNT=x
run_access_no_tools
[[ "${TASK_RC}" -ne 0 ]] || fail "cellCount 'x' must fail the task"
grep -qF "cellCount" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "cellCount error not named"; }
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "oc must not be called with invalid inputs"
setup
HUB_CLUSTER_SAVED="${HUB}"
HUB=""
run_access_no_tools
HUB="${HUB_CLUSTER_SAVED}"
[[ "${TASK_RC}" -ne 0 ]] || fail "an empty hubClusterName must fail the task"
grep -qF "hubClusterName" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "hubClusterName error not named"; }
echo "✅ PASS: invalid_inputs_fail"

# Test case: edge_node_id_result
echo ""
echo "Test: edge_node_id_result"
echo "--------------------------------------------"
setup
write_rules "{\"metadata\":{\"labels\":{\"edgelm.sap.com/edge-node-id\":\"${EDGE_NODE_ID}\"}}}"
# The rewrite script of wait-cluster-ready (remote hub) must be applied to the hosted kubeconfig
cat > "${WS}/.kubeconfig-rewrite.sh" <<EOF
echo "\$1" > "${WS}/rewritten"
EOF
run_access_no_tools
expect_success
[[ "$(result clusterEdgeNodeId)" == "${EDGE_NODE_ID}" ]] || { echo "${TASK_OUT}"; fail "clusterEdgeNodeId should be '${EDGE_NODE_ID}', got '$(result clusterEdgeNodeId)'"; }
assert_called "^get secret ${HUB}-kubeconfig -o jsonpath=\{\.data\.kubeconfig\}$"
assert_called "^--kubeconfig .*/hub-kubeconfig get secret ${CLUSTER}-admin-kubeconfig -n clusters -o jsonpath=\{\.data\.kubeconfig\}$"
assert_called "^--kubeconfig .*/hosted-kubeconfig get ns edgelm --ignore-not-found -o json$"
grep -q "/hosted-kubeconfig$" "${WS}/rewritten" 2>/dev/null || fail "the kubeconfig rewrite script was not applied to the hosted kubeconfig"
# Local hub (no hub Secret): the admin kubeconfig comes through the in-cluster ServiceAccount
setup
HUB_SECRET=""
write_rules "{\"metadata\":{\"labels\":{\"edgelm.sap.com/edge-node-id\":\"${EDGE_NODE_ID}\"}}}"
run_access_no_tools
expect_success
[[ "$(result clusterEdgeNodeId)" == "${EDGE_NODE_ID}" ]] || { echo "${TASK_OUT}"; fail "local hub: clusterEdgeNodeId should be '${EDGE_NODE_ID}', got '$(result clusterEdgeNodeId)'"; }
assert_called "^get secret ${CLUSTER}-admin-kubeconfig -n clusters -o jsonpath=\{\.data\.kubeconfig\}$"
assert_not_called "hub-kubeconfig"
# Namespace or label absent: ''
setup
write_rules ""
run_access_no_tools
expect_success
[[ -f "${RESULTS_DIR}/clusterEdgeNodeId" && -z "$(result clusterEdgeNodeId)" ]] || fail "clusterEdgeNodeId should be empty without the namespace, got '$(result clusterEdgeNodeId)'"
setup
write_rules '{"metadata":{"labels":{}}}'
run_access_no_tools
expect_success
[[ -f "${RESULTS_DIR}/clusterEdgeNodeId" && -z "$(result clusterEdgeNodeId)" ]] || fail "clusterEdgeNodeId should be empty without the label, got '$(result clusterEdgeNodeId)'"
echo "✅ PASS: edge_node_id_result"

# Test case: edge_node_id_unknown_on_read_error
echo ""
echo "Test: edge_node_id_unknown_on_read_error"
echo "--------------------------------------------"
# The namespace read fails: 'unknown', error category only (never the raw error)
setup
write_rules ""
{
  printf '%s\t%s\t%s\n' \
    "--kubeconfig */hosted-kubeconfig get ns edgelm --ignore-not-found -o json" 1 ""
  cat "${FAKE_OC_RULES}"
} > "${FAKE_OC_RULES}.new"
mv "${FAKE_OC_RULES}.new" "${FAKE_OC_RULES}"
printf '%s\t%s\n' \
  "--kubeconfig */hosted-kubeconfig get ns edgelm*" 'Unable to connect to the server: dial tcp 10.0.0.1:6443: connect: connection refused (token sha256~FAKE-TOKEN-0123)' \
  > "${FAKE_OC_STDERR_RULES}"
run_access_no_tools
expect_success
[[ "$(result clusterEdgeNodeId)" == "unknown" ]] || { echo "${TASK_OUT}"; fail "clusterEdgeNodeId should be 'unknown' on a read error, got '$(result clusterEdgeNodeId)'"; }
grep -qF "Could not read namespace edgelm (connection refused)" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error category not printed"; }
! grep -qF "FAKE-TOKEN-0123" <<< "${TASK_OUT}" || fail "raw oc stderr printed"
# Output that is not JSON is no proof of absence
setup
write_rules "Warning: not json"
run_access_no_tools
expect_success
[[ "$(result clusterEdgeNodeId)" == "unknown" ]] || { echo "${TASK_OUT}"; fail "clusterEdgeNodeId should be 'unknown' for non-JSON output, got '$(result clusterEdgeNodeId)'"; }
# The hosted admin kubeconfig cannot be read through the hub: 'unknown', the task goes on
setup
printf '%s\t%s\t%s\n' \
  "get secret ${HUB}-kubeconfig -o jsonpath={.data.kubeconfig}" 0 "${HUB_KUBECONFIG_B64}" \
  "--kubeconfig */hub-kubeconfig get secret ${CLUSTER}-admin-kubeconfig*" 1 "" \
  > "${FAKE_OC_RULES}"
run_access_no_tools
expect_success
[[ "$(result clusterEdgeNodeId)" == "unknown" ]] || { echo "${TASK_OUT}"; fail "clusterEdgeNodeId should be 'unknown' without the hosted kubeconfig, got '$(result clusterEdgeNodeId)'"; }
assert_not_called "get ns edgelm"
grep -qF "Could not read the hosted cluster kubeconfig" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "kubeconfig warning not printed"; }
# The hub kubeconfig Secret has no usable key: 'unknown'
setup
: > "${FAKE_OC_RULES}"
run_access_no_tools
expect_success
[[ "$(result clusterEdgeNodeId)" == "unknown" ]] || { echo "${TASK_OUT}"; fail "clusterEdgeNodeId should be 'unknown' without the hub kubeconfig, got '$(result clusterEdgeNodeId)'"; }
assert_not_called "admin-kubeconfig"
echo "✅ PASS: edge_node_id_unknown_on_read_error"

# Test case: proxy_configured_when_secret_exists
echo ""
echo "Test: proxy_configured_when_secret_exists"
echo "--------------------------------------------"
setup
write_rules ""
printf '%s\t%s\t%s\n' "get secret ${HUB}-proxy-config --ignore-not-found -o name" 0 "secret/${HUB}-proxy-config" >> "${FAKE_OC_RULES}"
run_access_no_tools
expect_success
[[ "$(result proxyConfigured)" == "true" ]] || { echo "${TASK_OUT}"; fail "proxyConfigured should be 'true', got '$(result proxyConfigured)'"; }
assert_called "^get secret ${HUB}-proxy-config --ignore-not-found -o name$"
# Absent: false
setup
write_rules ""
run_access_no_tools
expect_success
[[ "$(result proxyConfigured)" == "false" ]] || { echo "${TASK_OUT}"; fail "proxyConfigured should be 'false' without the Secret, got '$(result proxyConfigured)'"; }
# Cannot be checked: true (the browser hands over at Add Edge Node rather than guessing)
setup
write_rules ""
printf '%s\t%s\t%s\n' "get secret ${HUB}-proxy-config --ignore-not-found -o name" 1 "" >> "${FAKE_OC_RULES}"
run_access_no_tools
expect_success
[[ "$(result proxyConfigured)" == "true" ]] || { echo "${TASK_OUT}"; fail "proxyConfigured should be 'true' when the Secret cannot be checked, got '$(result proxyConfigured)'"; }
echo "✅ PASS: proxy_configured_when_secret_exists"

# Test case: runner_rbac
echo ""
echo "Test: runner_rbac"
echo "--------------------------------------------"
python3 -I - "${RUNNER_RBAC}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    docs = {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(f) if d}

errors = []
runner = "hcp-sap-browser-runner"
manager = "hcp-sap-browser-access-manager"
if ("ServiceAccount", runner) not in docs:
    errors.append(f"ServiceAccount {runner} missing")
want_rules = [
    {"apiGroups": ["tekton.dev"], "resources": ["pipelineruns", "taskruns"], "verbs": ["get"]},
    {"apiGroups": [""], "resources": ["services"], "verbs": ["create", "get", "delete"]},
    {"apiGroups": ["route.openshift.io"], "resources": ["routes"], "verbs": ["create", "get", "delete"]},
    {"apiGroups": [""], "resources": ["serviceaccounts"], "verbs": ["get", "patch"], "resourceNames": [runner]},
]
role = docs.get(("Role", runner), {})
if role.get("rules") != want_rules:
    errors.append(f"Role {runner} rules should be {want_rules}, got {role.get('rules')}")
if "secrets" in str(role.get("rules")):
    errors.append("the runner Role must not grant Secrets (the per-run Role does)")
manager_role = docs.get(("Role", manager), {})
want_manager = [{"apiGroups": ["rbac.authorization.k8s.io"], "resources": ["roles", "rolebindings"],
                 "verbs": ["get", "create", "patch", "delete"]}]
if manager_role.get("rules") != want_manager:
    errors.append(f"Role {manager} rules should be {want_manager}, got {manager_role.get('rules')}")
for name, subject in ((runner, runner), (manager, "pipeline")):
    binding = docs.get(("RoleBinding", name), {})
    if binding.get("subjects") != [{"kind": "ServiceAccount", "name": subject}] or \
            binding.get("roleRef") != {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name}:
        errors.append(f"RoleBinding {name} must bind Role {name} to ServiceAccount {subject}, got {binding}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
[[ ! -e ../../hack/sap-browser/runner-rbac.yaml ]] || fail "hack/sap-browser/runner-rbac.yaml (namespace-wide get secrets) must be removed"
echo "✅ PASS: runner_rbac"

# Test case: browser_task_definition
echo ""
echo "Test: browser_task_definition"
echo "--------------------------------------------"
python3 -I - "${BROWSER_TASK}" ../../.tekton/tasks/roks-sap-browser-task.yaml \
  ../../hack/sap-browser/hcp-pipeline.mjs ../../hack/sap-browser/browser-session.mjs <<'PY'
import re
import sys
import yaml


def load_task(path):
    with open(path, encoding="utf-8") as f:
        return next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")


task = load_task(sys.argv[1])
roks = load_task(sys.argv[2])
sources = ""
for path in sys.argv[3:]:
    with open(path, encoding="utf-8") as f:
        sources += f.read()

errors = []
MISSING = object()
spec = task["spec"]
if task["metadata"]["name"] != "hcp-sap-browser":
    errors.append("task must be named hcp-sap-browser")

params = {p["name"]: p.get("default", MISSING) for p in spec["params"]}
expected_params = {
    "mode": MISSING,
    "phase": MISSING,
    "runnerImage": MISSING,
    "oauthProxyImage": "image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4",
    "elmUrl": "",
    "elmUrlSecretName": "sap-elm-url",
    "pipelineRun": MISSING,
    "pipelineRunUID": MISSING,
    "hostedClusterName": MISSING,
    "s3Prefix": MISSING,
    "cellCount": "",
    "datastoreType": MISSING,
    "highAvailability": "false",
    "deploymentNamePrefix": MISSING,
    "eicSolution": MISSING,
    "eicKeyAlias": MISSING,
    "eicInstallVersion": "",
    "eicUpgradeVersion": "",
    "registrySecretName": MISSING,
    "proxyConfigured": "false",
    "obcName": MISSING,
    "clusterEdgeNodeId": "",
    "runnerServiceAccount": "hcp-sap-browser-runner",
    "sessionMinutes": "360",
    "loginMinutes": "30",
}
if params.keys() != expected_params.keys():
    errors.append(f"params differ: extra {sorted(params.keys() - expected_params.keys())}, missing {sorted(expected_params.keys() - params.keys())}")
for name, default in expected_params.items():
    if name in params and params[name] is not default and params[name] != default:
        errors.append(f"param {name}: default should be {'<none>' if default is MISSING else repr(default)}, got {params[name]!r}")

if [r["name"] for r in spec.get("results", [])] != ["outcome"]:
    errors.append("expected exactly the result 'outcome'")
workspaces = spec.get("workspaces", [])
if [w["name"] for w in workspaces] != ["source"] or workspaces[0].get("readOnly") is not True or workspaces[0].get("optional") is not True:
    errors.append("expected exactly the workspace 'source', readOnly and optional")

# Pod shape as the ROKS task: memory volumes, OAuth proxy sidecar, one browser step
for key in ("volumes", "sidecars"):
    if spec.get(key) != roks["spec"].get(key):
        errors.append(f"{key} must match roks-sap-browser")
steps = spec["steps"]
if [s["name"] for s in steps] != ["browser"]:
    errors.append("expected exactly one step named 'browser'")
step = steps[0]
roks_step = roks["spec"]["steps"][0]
for key in ("image", "securityContext", "computeResources", "volumeMounts"):
    if step.get(key) != roks_step.get(key):
        errors.append(f"step {key} must match roks-sap-browser: {step.get(key)}")
script = step.get("script", "")
for needle in ("set -euo pipefail", 'dumb-init -- bash "${SAP_BROWSER_ENTRYPOINT:-/opt/sap-browser/entrypoint.sh}" || true',
               "printf 'failed'", "exit 0"):
    if needle not in script:
        errors.append(f"step script must contain {needle!r}")
if "set -x" in script or step.get("onError"):
    errors.append("no set -x and no onError: the script itself exits 0")

env = {e["name"]: e for e in step.get("env", [])}
values = {
    "SAP_BROWSER_ACCESS": "route",
    "SAP_BROWSER_ENTRY": "hcp-pipeline.mjs",
    "SAP_BROWSER_SOURCE_BOUND": "$(workspaces.source.bound)",
    "SAP_BROWSER_SOURCE": "$(workspaces.source.path)",
    "SAP_BROWSER_MODE": "$(params.mode)",
    "SAP_BROWSER_PHASE": "$(params.phase)",
    "SAP_ELM_URL": "$(params.elmUrl)",
    "PIPELINE_NAMESPACE": "$(context.taskRun.namespace)",
    "PIPELINE_RUN": "$(params.pipelineRun)",
    "PIPELINE_RUN_UID": "$(params.pipelineRunUID)",
    "TASKRUN_NAME": "$(context.taskRun.name)",
    "RUNNER_SERVICE_ACCOUNT": "$(params.runnerServiceAccount)",
    "HOSTED_CLUSTER_NAME": "$(params.hostedClusterName)",
    "S3_PREFIX": "$(params.s3Prefix)",
    "CELL_COUNT": "$(params.cellCount)",
    "DATASTORE_TYPE": "$(params.datastoreType)",
    "HIGH_AVAILABILITY": "$(params.highAvailability)",
    "DEPLOYMENT_NAME_PREFIX": "$(params.deploymentNamePrefix)",
    "SAP_EIC_SOLUTION": "$(params.eicSolution)",
    "SAP_EIC_KEY_ALIAS": "$(params.eicKeyAlias)",
    "SAP_EIC_INSTALL_VERSION": "$(params.eicInstallVersion)",
    "SAP_EIC_UPGRADE_VERSION": "$(params.eicUpgradeVersion)",
    "REGISTRY_SECRET": "$(params.registrySecretName)",
    "PROXY_CONFIGURED": "$(params.proxyConfigured)",
    "CLUSTER_EDGE_NODE_ID": "$(params.clusterEdgeNodeId)",
    "SAP_BROWSER_SESSION_MINUTES": "$(params.sessionMinutes)",
    "SAP_BROWSER_LOGIN_MINUTES": "$(params.loginMinutes)",
    "SAP_BROWSER_RESULT_PATH": "$(results.outcome.path)",
}
field_refs = {"POD_NAME": "metadata.name", "POD_UID": "metadata.uid", "POD_SERVICE_ACCOUNT": "spec.serviceAccountName"}
secret_refs = {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"}
configmap_refs = {"BUCKET_HOST", "BUCKET_PORT", "BUCKET_NAME"}
for name, value in values.items():
    if env.get(name) != {"name": name, "value": value}:
        errors.append(f"env {name} should be {value!r}, got {env.get(name)}")
for name, path in field_refs.items():
    if env.get(name) != {"name": name, "valueFrom": {"fieldRef": {"fieldPath": path}}}:
        errors.append(f"env {name} should come from fieldRef {path}, got {env.get(name)}")
for name in secret_refs:
    if env.get(name) != {"name": name, "valueFrom": {"secretKeyRef": {"name": "$(params.obcName)", "key": name}}}:
        errors.append(f"env {name} should come from the OBC Secret, got {env.get(name)}")
for name in configmap_refs:
    if env.get(name) != {"name": name, "valueFrom": {"configMapKeyRef": {"name": "$(params.obcName)", "key": name}}}:
        errors.append(f"env {name} should come from the OBC ConfigMap, got {env.get(name)}")
elm_url_ref = {"name": "SAP_ELM_URL_FROM_SECRET", "valueFrom": {"secretKeyRef": {"name": "$(params.elmUrlSecretName)", "key": "url", "optional": True}}}
if env.get("SAP_ELM_URL_FROM_SECRET") != elm_url_ref:
    errors.append(f"env SAP_ELM_URL_FROM_SECRET should come from the optional Secret elmUrlSecretName (key url), got {env.get('SAP_ELM_URL_FROM_SECRET')}")
expected_names = set(values) | set(field_refs) | secret_refs | configmap_refs | {"SAP_ELM_URL_FROM_SECRET"}
if set(env) != expected_names:
    errors.append(f"unexpected/missing env: extra {sorted(set(env) - expected_names)}, missing {sorted(expected_names - set(env))}")

# Every variable the HCP session reads must be set by the task, except the
# session dir (entrypoint.sh), the debug switches it refuses, the storage
# class (default nfs-rwx) and the hub Secret (the HCP profile ignores the hub).
read = set(re.findall(r"\benv\.([A-Z][A-Z0-9_]*)", sources))
read |= set(re.findall(r"\benv\[\s*'([A-Z][A-Z0-9_]*)'\s*\]", sources))
read |= set(re.findall(r"flag\(env,\s*'([A-Z][A-Z0-9_]*)'\)", sources))
for line in sources.splitlines():
    if re.search(r"for \(const key of \[", line):
        read.update(re.findall(r"'([A-Z][A-Z0-9_]*)'", line))
not_from_task = {"SAP_BROWSER_SESSION_DIR", "PWDEBUG", "DEBUG", "SHARED_FS_STORAGE_CLASS", "HUB_KUBECONFIG_SECRET_NAME"}
missing = sorted(read - not_from_task - set(env))
if missing:
    errors.append(f"the HCP session reads env the task does not set: {missing}")
if not {"HIGH_AVAILABILITY", "PROXY_CONFIGURED", "CELL_COUNT", "SAP_EIC_UPGRADE_VERSION"} <= read:
    errors.append(f"env scan of the HCP session found too few names: {sorted(read)}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: browser_task_definition"

# Test case: browser_step_always_exits_zero
echo ""
echo "Test: browser_step_always_exits_zero"
echo "--------------------------------------------"
FAKE_BIN=$(tmp_dir)
cat > "${FAKE_BIN}/dumb-init" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--" ]]; then shift; fi
exec "$@"
EOF
chmod +x "${FAKE_BIN}/dumb-init"
run_browser_step() {
  RESULTS_DIR=$(tmp_dir)
  export SAP_BROWSER_RESULT_PATH="${RESULTS_DIR}/outcome"
  PATH="${FAKE_BIN}:${PATH}" run_task "${BROWSER_TASK}" --step browser \
    --param mode=auto --param phase=deploy \
    --param runnerImage=example.com/sap-browser:test \
    --param elmUrl=https://elm.example.com/ \
    --param pipelineRun=hcp-ossm3-validation-pr42-abcde \
    --param pipelineRunUID=0f6c1e4a-1111-2222-3333-444455556666 \
    --param hostedClusterName="${CLUSTER}" \
    --param s3Prefix="restricted-resources/${CLUSTER}/" \
    --param datastoreType=redis \
    --param deploymentNamePrefix=pr-42 \
    --param eicSolution="Edge Integration Cell (dev)" \
    --param eicKeyAlias=slv-ic \
    --param registrySecretName="${HUB}-quay-robot" \
    --param obcName=sap-eic-restricted-cluster-config-resources \
    --results-dir "${RESULTS_DIR}"
}
export SAP_BROWSER_ENTRYPOINT=false
run_browser_step
expect_success
[[ "$(result outcome)" == "failed" ]] || { echo "${TASK_OUT}"; fail "outcome should be 'failed' when the entrypoint fails, got '$(result outcome)'"; }
FAKE_ENTRYPOINT="${FAKE_BIN}/entrypoint-handed-over.sh"
printf "printf 'handed-over' > \"\${SAP_BROWSER_RESULT_PATH}\"\nexit 3\n" > "${FAKE_ENTRYPOINT}"
export SAP_BROWSER_ENTRYPOINT="${FAKE_ENTRYPOINT}"
run_browser_step
expect_success
[[ "$(result outcome)" == "handed-over" ]] || { echo "${TASK_OUT}"; fail "outcome should stay 'handed-over', got '$(result outcome)'"; }

# elm_url_from_secret: an empty elmUrl param takes the URL from the Secret
# (SAP_ELM_URL_FROM_SECRET, secretKeyRef optional); a set param wins; the
# Secret variable never reaches the entry point.
FAKE_ENTRYPOINT="${FAKE_BIN}/entrypoint-url.sh"
cat > "${FAKE_ENTRYPOINT}" <<'EOF'
printf '%s|%s' "${SAP_ELM_URL}" "${SAP_ELM_URL_FROM_SECRET-unset}" > "${URL_SEEN}"
printf deployed > "${SAP_BROWSER_RESULT_PATH}"
EOF
export SAP_BROWSER_ENTRYPOINT="${FAKE_ENTRYPOINT}"
URL_SEEN=$(tmp_file); export URL_SEEN
SAP_ELM_URL="" SAP_ELM_URL_FROM_SECRET="https://tenant.example/elm/index.html" run_browser_step
expect_success
[[ "$(cat "${URL_SEEN}")" == "https://tenant.example/elm/index.html|unset" ]] || fail "empty elmUrl must take the Secret URL and unset the Secret variable, saw '$(cat "${URL_SEEN}")'"
SAP_ELM_URL="https://param.example/elm/" SAP_ELM_URL_FROM_SECRET="https://tenant.example/elm/index.html" run_browser_step
expect_success
[[ "$(cat "${URL_SEEN}")" == "https://param.example/elm/|unset" ]] || fail "a set elmUrl must win over the Secret, saw '$(cat "${URL_SEEN}")'"
echo "✅ PASS: elm_url_from_secret"
unset SAP_BROWSER_ENTRYPOINT SAP_BROWSER_RESULT_PATH
echo "✅ PASS: browser_step_always_exits_zero"

echo ""
echo "============================================"
echo "✅ All hcp-sap-browser-access tests passed"
echo "============================================"
