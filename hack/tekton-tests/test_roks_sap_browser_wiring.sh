#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0
# cspell:words benv findall isfile noqa PWDEBUG repr rstrip splitlines

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-sap-browser task and ROKS pipeline wiring"
echo "============================================"

TASK=../../.tekton/tasks/roks-sap-browser-task.yaml
HCP_TASK=../../.tekton/tasks/hcp-sap-browser-task.yaml
PIPELINE=../../.tekton/pipelines/roks-eic-full-test-pipeline.yaml
RUN_FILE=../../.tekton/roks-eic-ossm3-run.yaml
EXAMPLE_RUN_FILE=../../.tekton-examples/roks-eic-ossm3-run.yaml
ROKS_ENTRY=../../hack/sap-browser/roks-pipeline.mjs

[[ -f "${TASK}" ]] || fail "${TASK} not found"

# Test case: task_definition
echo ""
echo "Test: task_definition"
echo "--------------------------------------------"
python3 -I - "${TASK}" "${HCP_TASK}" "${ROKS_ENTRY}" <<'PY'
import re
import sys
import yaml


def load_task(path):
    with open(path, encoding="utf-8") as f:
        return next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")


task = load_task(sys.argv[1])
hcp = load_task(sys.argv[2])
with open(sys.argv[3], encoding="utf-8") as f:
    entry_source = f.read()

errors = []
MISSING = object()
spec = task["spec"]

if task["metadata"]["name"] != "roks-sap-browser":
    errors.append("task must be named roks-sap-browser")

params = {p["name"]: p.get("default", MISSING) for p in spec["params"]}
expected_params = {
    "mode": MISSING,
    "phase": MISSING,
    "runnerImage": MISSING,
    "oauthProxyImage": "image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4",
    "elmUrl": MISSING,
    "pipelineRun": MISSING,
    "pipelineRunUID": MISSING,
    "clusterName": MISSING,
    "obcName": MISSING,
    "roksCredentialsSecretName": MISSING,
    "hubKubeconfigSecretName": MISSING,
    "clusterEdgeNodeId": "",
    "runnerServiceAccount": "roks-sap-browser-runner",
    "sessionMinutes": "180",
    "loginMinutes": "30",
}
if params.keys() != expected_params.keys():
    errors.append(f"params differ: {sorted(params)} vs {sorted(expected_params)}")
for name, default in expected_params.items():
    if name in params and params[name] is not default and params[name] != default:
        errors.append(f"param {name}: default should be {'<none>' if default is MISSING else repr(default)}, got {params[name]!r}")

if [r["name"] for r in spec.get("results", [])] != ["outcome"]:
    errors.append("expected exactly the result 'outcome'")

workspaces = spec.get("workspaces", [])
if [w["name"] for w in workspaces] != ["source"]:
    errors.append("expected exactly the workspace 'source'")
elif not (workspaces[0].get("readOnly") is True and workspaces[0].get("optional") is True):
    errors.append("workspace 'source' must be readOnly and optional (as hcp-sap-browser)")

# Memory volumes as hcp-sap-browser, plus memory-only storage for the cookie secret
volumes = {v["name"]: v for v in spec.get("volumes", [])}
for v in hcp["spec"]["volumes"]:
    if volumes.get(v["name"]) != v:
        errors.append(f"volume {v['name']} must match hcp-sap-browser: {volumes.get(v['name'])}")
for name, v in volumes.items():
    empty_dir = v.get("emptyDir") or {}
    if empty_dir.get("medium") != "Memory" or not empty_dir.get("sizeLimit"):
        errors.append(f"volume {name} must be a size-limited Memory emptyDir")

steps = spec["steps"]
hcp_step = hcp["spec"]["steps"][0]
if [s["name"] for s in steps] != ["browser"]:
    errors.append("expected exactly one step named 'browser' (the hand-over message uses -c step-browser)")
step = steps[0]
if step.get("image") != "$(params.runnerImage)":
    errors.append("step image must be $(params.runnerImage)")
if "command" in step or "args" in step:
    errors.append("step must use script, not command/args")
for key in ("securityContext", "computeResources", "volumeMounts"):
    if step.get(key) != hcp_step.get(key):
        errors.append(f"step {key} must match hcp-sap-browser: {step.get(key)}")
if step.get("onError"):
    errors.append("the script itself must exit 0; no onError")

script = step.get("script", "")
if "set -euo pipefail" not in script:
    errors.append("script must use set -euo pipefail")
if "set -x" in script:
    errors.append("script must not use set -x")
if 'dumb-init -- bash "${SAP_BROWSER_ENTRYPOINT:-/opt/sap-browser/entrypoint.sh}"' not in script:
    errors.append("script must run the entrypoint under dumb-init (resolved via PATH)")

env = {e["name"]: e for e in step.get("env", [])}
expected_values = {
    "SAP_BROWSER_ACCESS": "route",
    "SAP_BROWSER_ENTRY": "roks-pipeline.mjs",
    "SAP_BROWSER_SOURCE_BOUND": "$(workspaces.source.bound)",
    # The pipeline binds the workspace with subPath hack/sap-browser
    "SAP_BROWSER_SOURCE": "$(workspaces.source.path)",
    "SAP_BROWSER_MODE": "$(params.mode)",
    "SAP_BROWSER_PHASE": "$(params.phase)",
    "SAP_ELM_URL": "$(params.elmUrl)",
    "PIPELINE_NAMESPACE": "$(context.taskRun.namespace)",
    "PIPELINE_RUN": "$(params.pipelineRun)",
    "PIPELINE_RUN_UID": "$(params.pipelineRunUID)",
    "CLUSTER_NAME": "$(params.clusterName)",
    "TASKRUN_NAME": "$(context.taskRun.name)",
    "RUNNER_SERVICE_ACCOUNT": "$(params.runnerServiceAccount)",
    "S3_PREFIX": "restricted-resources/$(params.clusterName)/",
    "CLUSTER_EDGE_NODE_ID": "$(params.clusterEdgeNodeId)",
    "HUB_KUBECONFIG_SECRET_NAME": "$(params.hubKubeconfigSecretName)",
    "SAP_BROWSER_SESSION_MINUTES": "$(params.sessionMinutes)",
    "SAP_BROWSER_LOGIN_MINUTES": "$(params.loginMinutes)",
    "SAP_BROWSER_RESULT_PATH": "$(results.outcome.path)",
}
field_refs = {"POD_NAME": "metadata.name", "POD_UID": "metadata.uid",
              # checked against RUNNER_SERVICE_ACCOUNT (missing taskRunSpecs)
              "POD_SERVICE_ACCOUNT": "spec.serviceAccountName"}
secret_refs = {
    "AWS_ACCESS_KEY_ID": ("$(params.obcName)", "AWS_ACCESS_KEY_ID", False),
    "AWS_SECRET_ACCESS_KEY": ("$(params.obcName)", "AWS_SECRET_ACCESS_KEY", False),
    "POSTGRES_ADMIN_PASSWORD": ("$(params.roksCredentialsSecretName)", "POSTGRES_ADMIN_PASSWORD", True),
}
configmap_refs = {
    "BUCKET_HOST": ("$(params.obcName)", "BUCKET_HOST"),
    "BUCKET_PORT": ("$(params.obcName)", "BUCKET_PORT"),
    "BUCKET_NAME": ("$(params.obcName)", "BUCKET_NAME"),
}
for name, value in expected_values.items():
    if env.get(name) != {"name": name, "value": value}:
        errors.append(f"env {name} should be {value!r}, got {env.get(name)}")
for name, path in field_refs.items():
    if env.get(name) != {"name": name, "valueFrom": {"fieldRef": {"fieldPath": path}}}:
        errors.append(f"env {name} should come from fieldRef {path}, got {env.get(name)}")
for name, (secret, key, optional) in secret_refs.items():
    ref = {"name": secret, "key": key}
    if optional:
        ref["optional"] = True
    if env.get(name) != {"name": name, "valueFrom": {"secretKeyRef": ref}}:
        errors.append(f"env {name} should come from secretKeyRef {ref}, got {env.get(name)}")
for name, (configmap, key) in configmap_refs.items():
    if env.get(name) != {"name": name, "valueFrom": {"configMapKeyRef": {"name": configmap, "key": key}}}:
        errors.append(f"env {name} should come from configMapKeyRef {configmap}/{key}, got {env.get(name)}")
expected_names = set(expected_values) | set(field_refs) | set(secret_refs) | set(configmap_refs)
if set(env) != expected_names:
    errors.append(f"unexpected/missing env: extra {sorted(set(env) - expected_names)}, missing {sorted(expected_names - set(env))}")

# Every variable roks-pipeline.mjs reads must be set by the task, except the
# session dir (entrypoint.sh) and the debug switches it refuses.
read_by_entry = set(re.findall(r"\benv\.([A-Z][A-Z0-9_]*)", entry_source))
for line in entry_source.splitlines():
    if re.search(r"for \(const key of \[", line):
        read_by_entry.update(re.findall(r"'([A-Z][A-Z0-9_]*)'", line))
not_from_task = {"SAP_BROWSER_SESSION_DIR", "PWDEBUG", "DEBUG"}
missing = sorted(read_by_entry - not_from_task - set(env))
if missing:
    errors.append(f"roks-pipeline.mjs reads env the task does not set: {missing}")
if len(read_by_entry) < 20:
    errors.append(f"env scan of roks-pipeline.mjs found too few names: {sorted(read_by_entry)}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: task_definition"

# Test case: oauth_proxy_sidecar
echo ""
echo "Test: oauth_proxy_sidecar"
echo "--------------------------------------------"
SIDECAR_DIR=$(tmp_dir)
python3 -I - "${TASK}" "${SIDECAR_DIR}" <<'PY'
import os
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")
out_dir = sys.argv[2]

errors = []
spec = task["spec"]
sidecars = spec.get("sidecars", [])
if [s["name"] for s in sidecars] != ["oauth-proxy"]:
    print("expected exactly one sidecar named 'oauth-proxy'")
    sys.exit(1)
sidecar = sidecars[0]
if sidecar.get("image") != "$(params.oauthProxyImage)":
    errors.append("sidecar image must be $(params.oauthProxyImage)")

sar = '--openshift-sar={"namespace":"$(context.taskRun.namespace)","resource":"pods","subresource":"portforward","verb":"create"}'
args = sidecar.get("args", [])
if sar not in args:
    errors.append(f"sidecar args must contain exactly {sar}")
cookie_args = [a for a in args if a.startswith("--cookie-secret-file=")]
if len(cookie_args) != 1:
    errors.append(f"expected one --cookie-secret-file arg, got {cookie_args}")
    cookie_file = None
else:
    cookie_file = cookie_args[0].split("=", 1)[1]
expected_args = [
    "--provider=openshift",
    "--http-address=:4180",
    "--https-address=",
    "--upstream=http://127.0.0.1:6080",
    "--openshift-service-account=$(params.runnerServiceAccount)",
    f"--cookie-secret-file={cookie_file}",
    "--cookie-secure=true",
    "--skip-provider-button",
    "--pass-access-token=false",
    "--email-domain=*",
    sar,
]
if args != expected_args:
    errors.append(f"sidecar args differ:\n  got      {args}\n  expected {expected_args}")

command = sidecar.get("command", [])
if command[:2] != ["/bin/bash", "-c"] or len(command) != 4:
    errors.append(f"sidecar command must be [/bin/bash, -c, <script>, <name>], got {command}")
    script = ""
else:
    script = command[2]
for needle in ("set -euo pipefail", "/dev/urandom", 'oauth-proxy "$@" || status=$?', "exit 0"):
    if needle not in script:
        errors.append(f"sidecar script must contain {needle!r}")
# A sidecar exiting non-zero can fail the pod (restartPolicy Never): no exec
if "exec " in script:
    errors.append("sidecar script must run oauth-proxy as a child, not exec it")

# The cookie secret lives in a Memory volume mounted only into the sidecar
volumes = {v["name"]: v for v in spec.get("volumes", [])}
mounts = sidecar.get("volumeMounts", [])
if cookie_file:
    if cookie_file not in script:
        errors.append(f"sidecar script must write the cookie secret to {cookie_file}")
    holders = [m for m in mounts if cookie_file.startswith(m["mountPath"].rstrip("/") + "/")]
    if len(holders) != 1:
        errors.append(f"cookie secret file {cookie_file} must sit in one sidecar volume mount, got {mounts}")
    else:
        volume = volumes.get(holders[0]["name"], {})
        if (volume.get("emptyDir") or {}).get("medium") != "Memory":
            errors.append(f"cookie volume {holders[0]['name']} must be a Memory emptyDir")
        step_mounts = {m["name"] for m in spec["steps"][0].get("volumeMounts", [])}
        if holders[0]["name"] in step_mounts:
            errors.append("the browser step must not mount the cookie volume")

if sidecar.get("securityContext") != spec["steps"][0].get("securityContext"):
    errors.append("sidecar securityContext must match the browser step")

if errors:
    print("\n".join(errors))
    sys.exit(1)

# For the behavior check below: script with the cookie path moved to a temp dir
with open(os.path.join(out_dir, "script.sh"), "w", encoding="utf-8") as f:
    f.write(script.replace(cookie_file, os.path.join(out_dir, "cookie-secret")))
with open(os.path.join(out_dir, "args"), "w", encoding="utf-8") as f:
    f.write("\n".join(args) + "\n")
PY

# Run the sidecar script with a fake oauth-proxy: it must write a fresh
# secret (owner-only) and pass every arg through unchanged.
mkdir "${SIDECAR_DIR}/bin"
cat > "${SIDECAR_DIR}/bin/oauth-proxy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_OAUTH_PROXY_ARGS}"
exit "${FAKE_OAUTH_PROXY_EXIT:-0}"
EOF
chmod +x "${SIDECAR_DIR}/bin/oauth-proxy"
SIDECAR_ARGS=()
while IFS= read -r ARG; do SIDECAR_ARGS+=("${ARG}"); done < "${SIDECAR_DIR}/args"
FAKE_OAUTH_PROXY_ARGS="${SIDECAR_DIR}/received-args" PATH="${SIDECAR_DIR}/bin:${PATH}" \
  bash -c "$(cat "${SIDECAR_DIR}/script.sh")" oauth-proxy "${SIDECAR_ARGS[@]}" 2>/dev/null \
  || fail "sidecar script failed"
cmp -s "${SIDECAR_DIR}/args" "${SIDECAR_DIR}/received-args" \
  || fail "oauth-proxy did not receive the sidecar args unchanged: $(cat "${SIDECAR_DIR}/received-args")"
COOKIE="${SIDECAR_DIR}/cookie-secret"
[[ -s "${COOKIE}" ]] || fail "cookie secret not written"
[[ "$(wc -c < "${COOKIE}" | tr -d ' ')" -ge 32 ]] || fail "cookie secret shorter than 32 characters"
[[ "$(tr -d 'A-Za-z0-9+/=' < "${COOKIE}")" == "" ]] || fail "cookie secret must be printable base64 without a newline"
COOKIE_MODE=$(stat -c '%a' "${COOKIE}" 2>/dev/null || stat -f '%Lp' "${COOKIE}")
[[ "${COOKIE_MODE}" == "600" ]] || fail "cookie secret mode should be 600, got ${COOKIE_MODE}"
FIRST_COOKIE=$(cat "${COOKIE}")
rm -f "${COOKIE}"
FAKE_OAUTH_PROXY_ARGS="${SIDECAR_DIR}/received-args" PATH="${SIDECAR_DIR}/bin:${PATH}" \
  bash -c "$(cat "${SIDECAR_DIR}/script.sh")" oauth-proxy "${SIDECAR_ARGS[@]}" 2>/dev/null \
  || fail "sidecar script failed on the second run"
[[ "$(cat "${COOKIE}")" != "${FIRST_COOKIE}" ]] || fail "cookie secret must be random per start"

# oauth-proxy ending with an error must not fail the sidecar (and the pod)
SIDECAR_RC=0
SIDECAR_ERR=$(FAKE_OAUTH_PROXY_EXIT=7 FAKE_OAUTH_PROXY_ARGS="${SIDECAR_DIR}/received-args" PATH="${SIDECAR_DIR}/bin:${PATH}" \
  bash -c "$(cat "${SIDECAR_DIR}/script.sh")" oauth-proxy "${SIDECAR_ARGS[@]}" 2>&1 >/dev/null) || SIDECAR_RC=$?
[[ "${SIDECAR_RC}" -eq 0 ]] || fail "sidecar must exit 0 when oauth-proxy fails, got ${SIDECAR_RC}"
grep -qF "oauth-proxy exited with status 7" <<< "${SIDECAR_ERR}" || fail "sidecar must log the oauth-proxy status, got: ${SIDECAR_ERR}"

# Nor may a cookie secret that cannot be written
SIDECAR_RC=0
SIDECAR_ERR=$(FAKE_OAUTH_PROXY_ARGS="${SIDECAR_DIR}/received-args" PATH="${SIDECAR_DIR}/bin:${PATH}" \
  bash -c "$(sed "s|${SIDECAR_DIR}/cookie-secret|${SIDECAR_DIR}/missing-dir/cookie-secret|" "${SIDECAR_DIR}/script.sh")" \
  oauth-proxy "${SIDECAR_ARGS[@]}" 2>&1 >/dev/null) || SIDECAR_RC=$?
[[ "${SIDECAR_RC}" -eq 0 ]] || fail "sidecar must exit 0 when the cookie secret cannot be written, got ${SIDECAR_RC}"
grep -qF "oauth-proxy not started" <<< "${SIDECAR_ERR}" || fail "sidecar must log why oauth-proxy did not start, got: ${SIDECAR_ERR}"
echo "✅ PASS: oauth_proxy_sidecar"

# Test case: pipeline_wiring
echo ""
echo "Test: pipeline_wiring"
echo "--------------------------------------------"
python3 -I - "${PIPELINE}" ../.. <<'PY'
import os
import re
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    pipeline = yaml.safe_load(f)
repo = sys.argv[2]
spec = pipeline["spec"]
params = {p["name"]: p for p in spec["params"]}
tasks = {t["name"]: t for t in spec["tasks"]}
finally_tasks = {t["name"]: t for t in spec.get("finally", [])}
errors = []
MISSING = object()


def check(cond, msg):
    if not cond:
        errors.append(msg)


expected_params = {
    "sapBrowserMode": "disabled",
    "sapBrowserImage": "",
    "sapElmUrl": "",
    "sapBrowserSessionMinutes": "180",
    "sapBrowserLoginMinutes": "30",
    "oauthProxyImage": "image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4",
}
for name, default in expected_params.items():
    check(name in params, f"pipeline param {name} missing")
    if name in params:
        check(params[name].get("default", MISSING) == default,
              f"pipeline param {name}: default should be {default!r}, got {params[name].get('default')!r}")
mode_description = params.get("sapBrowserMode", {}).get("description", "")
for word in ("disabled", "inspect", "auto"):
    check(word in mode_description, f"sapBrowserMode description must name {word}")

# Both must hold: a mode other than disabled and an image (a pod without an
# image would fail the run)
when_enabled = [
    {"input": "$(params.sapBrowserMode)", "operator": "notin", "values": ["disabled"]},
    {"input": "$(params.sapBrowserImage)", "operator": "notin", "values": [""]},
]
full_workspace = [{"name": "source", "workspace": "source"}]
helper_code_only = [{"name": "source", "workspace": "source", "subPath": "hack/sap-browser"}]
browser_params = {
    "mode": "$(params.sapBrowserMode)",
    "runnerImage": "$(params.sapBrowserImage)",
    "oauthProxyImage": "$(params.oauthProxyImage)",
    "elmUrl": "$(params.sapElmUrl)",
    "pipelineRun": "$(context.pipelineRun.name)",
    "pipelineRunUID": "$(context.pipelineRun.uid)",
    "clusterName": "$(params.clusterName)",
    "obcName": "$(params.obcName)",
    "roksCredentialsSecretName": "$(params.roksCredentialsSecretName)",
    "hubKubeconfigSecretName": "$(params.hubKubeconfigSecretName)",
    "sessionMinutes": "$(params.sapBrowserSessionMinutes)",
    "loginMinutes": "$(params.sapBrowserLoginMinutes)",
}
expected = {
    # No `when`: sap-browser-deploy consumes its result, and a result missing
    # from a skipped task would skip every task after it (and teardown-roks).
    # With the browser off the task does nothing.
    "sap-browser-access": {
        "taskRef": "roks-sap-browser-access",
        "when": None,
        "runAfter": {"validate-and-get-access"},
        "params": {"clusterName": "$(params.clusterName)", "mode": "$(params.sapBrowserMode)",
                   "browserImage": "$(params.sapBrowserImage)"},
        # needs the ROKS kubeconfig at the workspace root
        "workspaces": full_workspace,
    },
    "sap-browser-deploy": {
        "taskRef": "roks-sap-browser",
        "when": when_enabled,
        "runAfter": {"sap-browser-access", "registry-access"},
        "params": {**browser_params, "phase": "deploy",
                   "clusterEdgeNodeId": "$(tasks.sap-browser-access.results.clusterEdgeNodeId)"},
        "workspaces": helper_code_only,
    },
    "sap-browser-teardown": {
        "taskRef": "roks-sap-browser",
        "when": when_enabled,
        "runAfter": {"approval-teardown"},
        "params": {**browser_params, "phase": "teardown"},
        "workspaces": helper_code_only,
    },
}
for name, want in expected.items():
    task = tasks.get(name)
    check(task is not None, f"task {name} missing")
    if task is None:
        continue
    check(task.get("taskRef") == {"name": want["taskRef"]}, f"{name}: taskRef should be {want['taskRef']}, got {task.get('taskRef')}")
    check(task.get("when") == want["when"], f"{name}: when should be {want['when']}, got {task.get('when')}")
    check(set(task.get("runAfter", [])) == want["runAfter"], f"{name}: runAfter should be {sorted(want['runAfter'])}, got {task.get('runAfter')}")
    got_params = {p["name"]: p["value"] for p in task.get("params", [])}
    check(got_params == want["params"], f"{name}: params differ:\n  got      {got_params}\n  expected {want['params']}")
    check(task.get("workspaces") == want["workspaces"],
          f"{name}: workspaces should be {want['workspaces']}, got {task.get('workspaces')}")
    check("retries" not in task, f"{name}: no retries (a rerun could repeat SAP actions)")
    check("timeout" not in task, f"{name}: no task timeout (a timed-out task fails the run; the session has its own limit)")

check(set(tasks["approval-elm-eic-iflow-deployed"].get("runAfter", [])) == {"configure-mesh-eic", "registry-access", "sap-browser-deploy"},
      f"approval-elm-eic-iflow-deployed runAfter should be [configure-mesh-eic, registry-access, sap-browser-deploy], got {tasks['approval-elm-eic-iflow-deployed'].get('runAfter')}")

# teardown-roks is a finally task (runs after sap-browser-teardown whatever its
# result), gated on the teardown approval only
check("teardown-roks" not in tasks, "teardown-roks must not be in tasks")
teardown = finally_tasks.get("teardown-roks")
check(teardown is not None, "teardown-roks must be in finally")
if teardown is not None:
    check(teardown.get("when") == [{"input": "$(tasks.approval-teardown.status)", "operator": "in", "values": ["Succeeded"]}],
          f"teardown-roks: when must be exactly $(tasks.approval-teardown.status) in [Succeeded], got {teardown.get('when')}")
    check("runAfter" not in teardown, "teardown-roks: finally tasks take no runAfter")
    check(teardown.get("taskRef") == {"name": "roks-teardown"}, f"teardown-roks: taskRef should be roks-teardown, got {teardown.get('taskRef')}")
    check(teardown.get("workspaces") == full_workspace, f"teardown-roks: needs the full workspace, got {teardown.get('workspaces')}")
check(set(finally_tasks) == {"teardown-roks"}, f"finally should hold only teardown-roks, got {sorted(finally_tasks)}")

# With subPath hack/sap-browser the helper code sits at the workspace root,
# where entrypoint.sh copies it from (SAP_BROWSER_SOURCE) and runs the entry.
helper_dir = os.path.join(repo, "hack", "sap-browser")
for name in ("roks-pipeline.mjs", "entrypoint.sh", "control.mjs"):
    check(os.path.isfile(os.path.join(helper_dir, name)), f"hack/sap-browser/{name} missing")
with open(os.path.join(helper_dir, "entrypoint.sh"), encoding="utf-8") as f:
    entrypoint = f.read()
for needle in ('helper_source="$SAP_BROWSER_SOURCE"',
               'tar --exclude=node_modules -C "$helper_source" -cf - .',
               'node "$SAP_BROWSER_SESSION_DIR/code/$entry"'):
    check(needle in entrypoint, f"entrypoint.sh no longer contains {needle!r}")

for name, task in tasks.items():
    if task.get("taskRef", {}).get("kind") == "ApprovalTask":
        check("when" not in task, f"ApprovalTask {name} must not carry when")

# Only sap-browser-deploy consumes the Edge Node ID
for name, task in tasks.items():
    if name != "sap-browser-deploy":
        check("sap-browser-access.results" not in str(task.get("params", [])),
              f"{name} must not consume sap-browser-access results")
RESULT_REF = re.compile(r"\$\(tasks\.([^.]+)\.results\.")
deploy_sources = set(RESULT_REF.findall(str(tasks.get("sap-browser-deploy", {}))))
check(deploy_sources == {"sap-browser-access"},
      f"sap-browser-deploy should read results of sap-browser-access only, got {sorted(deploy_sources)}")

# A task skipped by its own `when` does not block its dependents, but a task
# whose result is missing is skipped too, and that skip cascades. So no task
# with a `when` may have its results consumed by another task.
for name, task in {**tasks, **finally_tasks}.items():
    for source in set(RESULT_REF.findall(str(task))):
        producer = tasks.get(source, finally_tasks.get(source, {}))
        check("when" not in producer, f"{name} consumes results of {source}, which has a when (its skip would cascade)")


# sap-browser-access reads the cluster's Edge Node ID label before this run
# applies a zip: no apply task may be among its ancestors.
def ancestors(name, seen=None):
    seen = set() if seen is None else seen
    for parent in tasks.get(name, {}).get("runAfter", []):
        if parent not in seen:
            seen.add(parent)
            ancestors(parent, seen)
    return seen


apply_tasks = {n for n, t in tasks.items() if t.get("taskRef", {}).get("name") == "ossm3-download-and-apply-rbac"}
check(apply_tasks == {"apply-rbac-elm", "apply-rbac-eic"}, f"unexpected apply tasks: {sorted(apply_tasks)}")
check(not (ancestors("sap-browser-access") & apply_tasks),
      f"sap-browser-access must not run after an apply: ancestors {sorted(ancestors('sap-browser-access'))}")
# ...and every apply waits for it, so a zip uploaded by hand before
# sap-browser-access ran cannot be applied first (it has no `when`: no cascade)
for name in sorted(apply_tasks):
    check("sap-browser-access" in ancestors(name), f"{name} must run after sap-browser-access")
check("sap-browser-access" in tasks.get("apply-rbac-elm", {}).get("runAfter", []),
      "apply-rbac-elm must list sap-browser-access in runAfter")
check("when" not in tasks.get("sap-browser-access", {}), "sap-browser-access must not carry a when (apply-rbac-elm waits for it)")
check(not (ancestors("sap-browser-deploy") & apply_tasks),
      "sap-browser-deploy must start before the applies (it produces the zips)")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: pipeline_wiring"

# Test case: run_files
echo ""
echo "Test: run_files"
echo "--------------------------------------------"
cmp -s "${RUN_FILE}" "${EXAMPLE_RUN_FILE}" || fail "${RUN_FILE} and ${EXAMPLE_RUN_FILE} must be identical"
python3 -I - "${RUN_FILE}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
run = next(d for d in yaml.safe_load_all(text) if d and d.get("kind") == "PipelineRun")
errors = []

params = {p["name"]: p["value"] for p in run["spec"]["params"]}
if params.get("sapBrowserMode") != "disabled":
    errors.append(f"sapBrowserMode should be \"disabled\", got {params.get('sapBrowserMode')!r}")
if "taskRunSpecs" in run["spec"]:
    errors.append("taskRunSpecs must stay commented out while the browser is disabled")
# teardown-roks runs in finally: 3 destroy attempts of up to 2h plus the sweep
want_timeouts = {"pipeline": "336h", "tasks": "324h", "finally": "12h"}
if run["spec"].get("timeouts") != want_timeouts:
    errors.append(f"timeouts should be {want_timeouts}, got {run['spec'].get('timeouts')}")

lines = text.splitlines()
for name in ("sapBrowserImage", "sapElmUrl"):
    if not any(line.strip() == f"# - name: {name}" for line in lines):
        errors.append(f"commented example for {name} missing")


# The commented taskRunSpecs block must become valid YAML when uncommented
def uncomment_block(start_marker):
    for i, line in enumerate(lines):
        if line.strip() == start_marker:
            indent = line.index("#")
            block = []
            for raw in lines[i:]:
                if not raw.strip().startswith("#") or raw.index("#") != indent:
                    break
                body = raw[indent + 1:]
                block.append(body[1:] if body.startswith(" ") else body)
            return "\n".join(block)
    return None


block = uncomment_block("# taskRunSpecs:")
if block is None:
    errors.append("commented taskRunSpecs missing")
else:
    try:
        specs = yaml.safe_load(block)["taskRunSpecs"]
    except Exception as exc:  # noqa: BLE001 - report any parse problem
        errors.append(f"commented taskRunSpecs is not valid YAML when uncommented: {exc}")
        specs = []
    want = [
        {"pipelineTaskName": "sap-browser-deploy", "serviceAccountName": "roks-sap-browser-runner"},
        {"pipelineTaskName": "sap-browser-teardown", "serviceAccountName": "roks-sap-browser-runner"},
    ]
    if specs != want:
        errors.append(f"commented taskRunSpecs should be {want}, got {specs}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: run_files"

# --- Step script: always exit 0, report "failed" when the runner left no outcome ---
FAKE_BIN=$(tmp_dir)
DUMB_INIT_LOG=$(tmp_file)
export DUMB_INIT_LOG
# Stand-in for /usr/bin/dumb-init: logs its arguments, drops "--", runs the rest.
cat > "${FAKE_BIN}/dumb-init" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DUMB_INIT_LOG}"
if [[ "${1:-}" == "--" ]]; then shift; fi
exec "$@"
EOF
chmod +x "${FAKE_BIN}/dumb-init"
export PATH="${FAKE_BIN}:${PATH}"

run_browser_step() {
  RESULTS_DIR=$(tmp_dir)
  export SAP_BROWSER_RESULT_PATH="${RESULTS_DIR}/outcome"
  : > "${DUMB_INIT_LOG}"
  run_task "${TASK}" --step browser \
    --param mode=auto \
    --param phase=deploy \
    --param runnerImage=example.com/sap-browser:test \
    --param elmUrl=https://elm.example.com/ \
    --param pipelineRun=roks-eic-full-test-pr7-abcde \
    --param pipelineRunUID=0f6c1e4a-1111-2222-3333-444455556666 \
    --param clusterName=redhat-roks-eic-pr7 \
    --param obcName=sap-eic-restricted-cluster-config-resources \
    --param roksCredentialsSecretName=roks-ci-credentials \
    --param hubKubeconfigSecretName= \
    --results-dir "${RESULTS_DIR}"
}

outcome() {
  cat "${RESULTS_DIR}/outcome" 2>/dev/null || true
}

expect_rc_zero() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
    fail "step must always exit 0, got ${TASK_RC}"
  fi
}

# Test case: step_failed_when_entrypoint_fails
echo ""
echo "Test: step_failed_when_entrypoint_fails"
echo "--------------------------------------------"
export SAP_BROWSER_ENTRYPOINT=false
run_browser_step
expect_rc_zero
[[ "$(outcome)" == "failed" ]] || { echo "${TASK_OUT}"; fail "outcome should be 'failed', got '$(outcome)'"; }
grep -qxF -- "-- bash false" "${DUMB_INIT_LOG}" || fail "dumb-init not called with '-- bash false': $(cat "${DUMB_INIT_LOG}")"
echo "✅ PASS: step_failed_when_entrypoint_fails"

# Test case: step_keeps_runner_outcome
echo ""
echo "Test: step_keeps_runner_outcome"
echo "--------------------------------------------"
FAKE_ENTRYPOINT="${FAKE_BIN}/entrypoint-deployed.sh"
cat > "${FAKE_ENTRYPOINT}" <<'EOF'
printf 'deployed' > "${SAP_BROWSER_RESULT_PATH}"
EOF
export SAP_BROWSER_ENTRYPOINT="${FAKE_ENTRYPOINT}"
run_browser_step
expect_rc_zero
[[ "$(outcome)" == "deployed" ]] || { echo "${TASK_OUT}"; fail "outcome should be 'deployed', got '$(outcome)'"; }
grep -qxF -- "-- bash ${FAKE_ENTRYPOINT}" "${DUMB_INIT_LOG}" || fail "dumb-init not called with the entrypoint: $(cat "${DUMB_INIT_LOG}")"
echo "✅ PASS: step_keeps_runner_outcome"

# Test case: step_keeps_outcome_when_runner_exits_nonzero
echo ""
echo "Test: step_keeps_outcome_when_runner_exits_nonzero"
echo "--------------------------------------------"
FAKE_ENTRYPOINT="${FAKE_BIN}/entrypoint-handed-over.sh"
cat > "${FAKE_ENTRYPOINT}" <<'EOF'
printf 'handed-over' > "${SAP_BROWSER_RESULT_PATH}"
exit 3
EOF
export SAP_BROWSER_ENTRYPOINT="${FAKE_ENTRYPOINT}"
run_browser_step
expect_rc_zero
[[ "$(outcome)" == "handed-over" ]] || { echo "${TASK_OUT}"; fail "outcome should stay 'handed-over', got '$(outcome)'"; }
echo "✅ PASS: step_keeps_outcome_when_runner_exits_nonzero"

# Test case: step_failed_when_runner_writes_nothing
echo ""
echo "Test: step_failed_when_runner_writes_nothing"
echo "--------------------------------------------"
FAKE_ENTRYPOINT="${FAKE_BIN}/entrypoint-silent.sh"
printf 'exit 0\n' > "${FAKE_ENTRYPOINT}"
export SAP_BROWSER_ENTRYPOINT="${FAKE_ENTRYPOINT}"
run_browser_step
expect_rc_zero
[[ "$(outcome)" == "failed" ]] || { echo "${TASK_OUT}"; fail "outcome should be 'failed', got '$(outcome)'"; }
echo "✅ PASS: step_failed_when_runner_writes_nothing"
unset SAP_BROWSER_ENTRYPOINT

echo ""
echo "============================================"
echo "✅ All roks-sap-browser wiring tests passed"
echo "============================================"
