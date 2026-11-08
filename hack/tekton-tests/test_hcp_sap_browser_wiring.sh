#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0
# cspell:words findall fullmatch isfile noqa repr splitlines

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: SAP browser wiring of the single-EIC HCP pipeline"
echo "============================================"

PIPELINE=../../.tekton/pipelines/hcp-ossm3-validation-pipeline.yaml
RUN_FILE=../../.tekton/hcp-ossm3-validation-run.yaml
EXAMPLE_RUN_FILE=../../.tekton-examples/hcp-ossm3-validation-run.yaml
ENTRYPOINT=../../hack/sap-browser/entrypoint.sh

# Test case: pipeline_params
echo ""
echo "Test: pipeline_params"
echo "--------------------------------------------"
python3 -I - "${PIPELINE}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    params = {p["name"]: p for p in yaml.safe_load(f)["spec"]["params"]}
errors = []
MISSING = object()

expected = {
    "sapBrowserMode": "disabled",
    "sapBrowserImage": "",
    "sapElmUrl": "",
    "sapBrowserHA": "false",
    "sapBrowserSessionMinutes": "360",
    "sapBrowserLoginMinutes": "30",
    "oauthProxyImage": "registry.redhat.io/openshift4/ose-oauth-proxy-rhel9:v4.20",
    "sapEicSolution": "Edge Integration Cell (dev)",
    "sapEicKeyAlias": "slv-ic",
    "sapEicInstallVersion": "",
    "sapEicUpgradeVersion": "",
}
for name, default in expected.items():
    got = params.get(name, {}).get("default", MISSING)
    if got is MISSING or got != default:
        errors.append(f"param {name}: default should be {default!r}, got {'<missing>' if got is MISSING else repr(got)}")
for gone in ("sapBrowserFlow",):
    if gone in params:
        errors.append(f"param {gone} must be removed (no custom flows in the pipeline)")
mode = params.get("sapBrowserMode", {}).get("description", "")
for word in ("disabled", "inspect", "auto"):
    if word not in mode:
        errors.append(f"sapBrowserMode description must name {word}")
for stale in ("review-registration", "or run"):
    if stale in mode:
        errors.append(f"sapBrowserMode description still names the old mode {stale.split()[-1]!r}")
session = params.get("sapBrowserSessionMinutes", {}).get("description", "")
if "1-600" not in session:
    errors.append("sapBrowserSessionMinutes description must give the allowed range 1-600")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: pipeline_params"

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
    spec = yaml.safe_load(f)["spec"]
repo = sys.argv[2]
tasks = {t["name"]: t for t in spec["tasks"]}
finally_tasks = {t["name"]: t for t in spec.get("finally", [])}
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


IMAGE = "$(tasks.sap-browser-image.results.image)"
# Both must hold: a mode other than disabled and an image (sap-browser-image
# gives an empty image with the browser off; a pod without an image would fail
# the run)
when_enabled = [
    {"input": "$(params.sapBrowserMode)", "operator": "notin", "values": ["disabled"]},
    {"input": IMAGE, "operator": "notin", "values": [""]},
]
full_workspace = [{"name": "source", "workspace": "source"}]
helper_code_only = [{"name": "source", "workspace": "source", "subPath": "hack/sap-browser"}]
browser_params = {
    "mode": "$(params.sapBrowserMode)",
    "runnerImage": IMAGE,
    "oauthProxyImage": "$(params.oauthProxyImage)",
    "elmUrl": "$(params.sapElmUrl)",
    "pipelineRun": "$(context.pipelineRun.name)",
    "pipelineRunUID": "$(context.pipelineRun.uid)",
    "hostedClusterName": "$(params.hostedClusterName)",
    "s3Prefix": "$(params.s3Prefix)",
    "cellCount": "",
    "datastoreType": "$(params.datastoreType)",
    "highAvailability": "$(params.sapBrowserHA)",
    "deploymentNamePrefix": "pr-$(params.pullRequestNumber)",
    "eicSolution": "$(params.sapEicSolution)",
    "eicKeyAlias": "$(params.sapEicKeyAlias)",
    "eicInstallVersion": "$(params.sapEicInstallVersion)",
    "eicUpgradeVersion": "$(params.sapEicUpgradeVersion)",
    "registrySecretName": "$(params.hubClusterName)-quay-robot",
    "obcName": "$(params.obcName)",
    "sessionMinutes": "$(params.sapBrowserSessionMinutes)",
    "loginMinutes": "$(params.sapBrowserLoginMinutes)",
}
expected = {
    # No `when`: the browser tasks consume its result (empty with the browser off)
    "sap-browser-image": {
        "taskRef": "sap-browser-image",
        "when": None,
        "runAfter": {"fetch-repository"},
        "params": {"mode": "$(params.sapBrowserMode)", "image": "$(params.sapBrowserImage)"},
        # build context: the whole checkout
        "workspaces": full_workspace,
    },
    # No `when`: sap-browser-deploy consumes its results; a no-op when disabled
    "sap-browser-access": {
        "taskRef": "hcp-sap-browser-access",
        "when": None,
        "runAfter": {"wait-cluster-ready"},
        "params": {
            "hostedClusterName": "$(params.hostedClusterName)",
            "hostedClusterNamespace": "$(params.hostedClusterNamespace)",
            "hubKubeconfigSecretName": "$(params.hubClusterName)-kubeconfig",
            "hubClusterName": "$(params.hubClusterName)",
            "mode": "$(params.sapBrowserMode)",
            "cellCount": "",
        },
        # .kubeconfig-rewrite.sh for a remote hub
        "workspaces": full_workspace,
    },
    "sap-browser-deploy": {
        "taskRef": "hcp-sap-browser",
        "when": when_enabled,
        "runAfter": {"sap-browser-access"},
        "params": {**browser_params, "phase": "deploy",
                   "clusterEdgeNodeId": "$(tasks.sap-browser-access.results.clusterEdgeNodeId)",
                   "proxyConfigured": "$(tasks.sap-browser-access.results.proxyConfigured)"},
        "workspaces": helper_code_only,
    },
    "sap-browser-teardown": {
        "taskRef": "hcp-sap-browser",
        # skipTeardown keeps the cluster, so its Edge Node and EIC stay too
        "when": when_enabled + [{"input": "$(params.skipTeardown)", "operator": "in", "values": ["false"]}],
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
    check(set(task.get("runAfter", [])) == want["runAfter"],
          f"{name}: runAfter should be {sorted(want['runAfter'])}, got {task.get('runAfter')}")
    got_params = {p["name"]: p["value"] for p in task.get("params", [])}
    check(got_params == want["params"], f"{name}: params differ:\n  got      {got_params}\n  expected {want['params']}")
    check(task.get("workspaces") == want["workspaces"],
          f"{name}: workspaces should be {want['workspaces']}, got {task.get('workspaces')}")
    check("retries" not in task, f"{name}: no retries (a rerun could repeat SAP actions or builds)")

check("sap-browser" not in tasks, "the port-forward task sap-browser must be replaced")


def minutes(duration):
    total = 0
    for value, unit in re.findall(r"(\d+)([hms])", duration or ""):
        total += int(value) * {"h": 60, "m": 1, "s": 1 / 60}[unit]
    return total


# The deploy session may run up to 600 minutes; its task gets an hour more for
# scheduling and image pull. The teardown session keeps the run's task timeout.
deploy_timeout = tasks.get("sap-browser-deploy", {}).get("timeout")
check(minutes(deploy_timeout) >= 600 + 60,
      f"sap-browser-deploy: timeout must be at least the longest session (600 minutes) plus 1h, got {deploy_timeout!r}")
check("timeout" not in tasks.get("sap-browser-teardown", {}),
      "sap-browser-teardown: no task timeout (a timed-out task would also skip teardown-hosted-cluster)")

check("sap-browser-access" in tasks.get("apply-elm-resources", {}).get("runAfter", []),
      "apply-elm-resources must list sap-browser-access in runAfter")
# The deploy session uploads the EIC zip and then waits for configure-mesh-eic,
# so wait-eic-zip must not wait for it (deadlock until the session limit); the
# gate does, so it opens once the session deployed EIC and the iFlows.
check(set(tasks.get("wait-eic-zip", {}).get("runAfter", [])) == {"get-all-accesses"},
      f"wait-eic-zip runAfter should be [get-all-accesses], got {tasks.get('wait-eic-zip', {}).get('runAfter')}")
check(set(tasks.get("approval-elm-eic-iflow-deployed", {}).get("runAfter", [])) == {"configure-mesh-eic", "enable-monitoring", "sap-browser-deploy"},
      "approval-elm-eic-iflow-deployed runAfter should be [configure-mesh-eic, enable-monitoring, sap-browser-deploy], "
      f"got {tasks.get('approval-elm-eic-iflow-deployed', {}).get('runAfter')}")
check(set(tasks.get("teardown-hosted-cluster", {}).get("runAfter", [])) == {"approval-teardown", "sap-browser-teardown"},
      "teardown-hosted-cluster runAfter should be [approval-teardown, sap-browser-teardown], "
      f"got {tasks.get('teardown-hosted-cluster', {}).get('runAfter')}")

for name, task in tasks.items():
    if task.get("taskRef", {}).get("kind") == "ApprovalTask":
        check("when" not in task, f"ApprovalTask {name} must not carry when")

RESULT_REF = re.compile(r"\$\(tasks\.([^.]+)\.results\.")
# Only the browser tasks read the image and access results
for name, task in {**tasks, **finally_tasks}.items():
    sources = set(RESULT_REF.findall(str(task)))
    if name not in ("sap-browser-deploy", "sap-browser-teardown"):
        check(not sources & {"sap-browser-image", "sap-browser-access"},
              f"{name} must not consume sap-browser-image or sap-browser-access results")
check(set(RESULT_REF.findall(str(tasks.get("sap-browser-deploy", {})))) == {"sap-browser-image", "sap-browser-access"},
      "sap-browser-deploy should read results of sap-browser-image and sap-browser-access only")
check(set(RESULT_REF.findall(str(tasks.get("sap-browser-teardown", {})))) == {"sap-browser-image"},
      "sap-browser-teardown should read results of sap-browser-image only")

# A task skipped by its own `when` does not block its dependents, but a task
# whose result is missing is skipped too, and that skip cascades. So no task
# with a `when` may have its results consumed by another task.
for name, task in {**tasks, **finally_tasks}.items():
    for source in set(RESULT_REF.findall(str(task))):
        producer = tasks.get(source, finally_tasks.get(source, {}))
        check("when" not in producer, f"{name} consumes results of {source}, which has a when (its skip would cascade)")


def ancestors(name, seen=None):
    seen = set() if seen is None else seen
    for parent in tasks.get(name, {}).get("runAfter", []):
        if parent not in seen:
            seen.add(parent)
            ancestors(parent, seen)
    return seen


# sap-browser-access reads the cluster's Edge Node ID label before this run
# applies a zip, and every apply waits for it
apply_tasks = {n for n, t in tasks.items() if t.get("taskRef", {}).get("name") == "ossm3-download-and-apply-rbac"}
check(apply_tasks == {"apply-elm-resources", "apply-eic-resources"}, f"unexpected apply tasks: {sorted(apply_tasks)}")
check(not (ancestors("sap-browser-access") & apply_tasks),
      f"sap-browser-access must not run after an apply: ancestors {sorted(ancestors('sap-browser-access'))}")
for name in sorted(apply_tasks):
    check("sap-browser-access" in ancestors(name), f"{name} must run after sap-browser-access")
check(not (ancestors("sap-browser-deploy") & apply_tasks),
      "sap-browser-deploy must start before the applies (it produces the zips)")
# The pipeline tasks the deploy session waits for (hcp-pipeline.mjs, single
# EIC) must not wait for the session themselves
with open(os.path.join(repo, "hack", "sap-browser", "hcp-pipeline.mjs"), encoding="utf-8") as f:
    hcp_entry = f.read()
waited = {"generate-sa-based-kubeconfig", "get-all-accesses", "configure-mesh-eic"}
for name in sorted(waited):
    check(f"'{name}'" in hcp_entry, f"hcp-pipeline.mjs no longer waits for {name}: update this test")
    check(name in tasks, f"task {name} (waited for by the deploy session) missing")
    check("sap-browser-deploy" not in ancestors(name),
          f"{name} runs after sap-browser-deploy, which waits for it: deadlock until the session limit")

# With subPath hack/sap-browser the helper code sits at the workspace root
helper_dir = os.path.join(repo, "hack", "sap-browser")
for name in ("hcp-pipeline.mjs", "entrypoint.sh", "control.mjs"):
    check(os.path.isfile(os.path.join(helper_dir, name)), f"hack/sap-browser/{name} missing")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: pipeline_wiring"

# Test case: run_files
echo ""
echo "Test: run_files"
echo "--------------------------------------------"
# The PR run file (.tekton/) is optional; when present it must equal the example
if [[ -f "${RUN_FILE}" ]]; then
  cmp -s "${RUN_FILE}" "${EXAMPLE_RUN_FILE}" || fail "${RUN_FILE} and ${EXAMPLE_RUN_FILE} must be identical"
fi
python3 -I - "${EXAMPLE_RUN_FILE}" <<'PY'
import re
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
# hcp-pipeline.mjs accepts only a sub-folder of restricted-resources/
if not re.fullmatch(r"restricted-resources/[a-z0-9][a-z0-9.{}_ -]*/", params.get("s3Prefix", "")):
    errors.append(f"s3Prefix must be a per-run sub-folder of restricted-resources/, got {params.get('s3Prefix')!r}")
for stale in (r"review-registration", r"(?<![a-z-])sap-browser-runner", r"pipelineTaskName: sap-browser$", r"sapBrowserFlow"):
    if re.search(stale, text, re.MULTILINE):
        errors.append(f"run file still mentions {stale!r}")

lines = text.splitlines()
for name in ("sapElmUrl",):
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
        {"pipelineTaskName": "sap-browser-deploy", "serviceAccountName": "hcp-sap-browser-runner"},
        {"pipelineTaskName": "sap-browser-teardown", "serviceAccountName": "hcp-sap-browser-runner"},
    ]
    if specs != want:
        errors.append(f"commented taskRunSpecs should be {want}, got {specs}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: run_files"

# Test case: port_forward_variant_removed
echo ""
echo "Test: port_forward_variant_removed"
echo "--------------------------------------------"
for GONE in ../../hack/sap-browser/pipeline.mjs ../../.tekton-examples/hcp-sap-browser-taskrun.yaml; do
  [[ ! -e "${GONE}" ]] || fail "${GONE} must be removed (port-forward variant)"
done
STALE=$(grep -rn -E "hcp-sap-browser-taskrun|(^|[^a-z-])runner-rbac\.yaml|(^|[^a-z-])pipeline\.mjs|sapBrowserFlow|review-registration" \
  ../../.tekton ../../.tekton-examples ../../hack/sap-browser/PIPELINE.md ../../hack/sap-browser/entrypoint.sh \
  ../../hack/sap-browser/browser-session.mjs ../../hack/sap-browser/session.test.mjs 2>/dev/null || true)
STALE+=$(grep -n "port-forward" ../../hack/sap-browser/PIPELINE.md ../../hack/sap-browser/README.md \
  ../../hack/sap-browser/entrypoint.sh "${PIPELINE}" "${EXAMPLE_RUN_FILE}" || true)
[[ -z "${STALE}" ]] || fail "stale references to the port-forward variant:
${STALE}"
echo "✅ PASS: port_forward_variant_removed"

# Test case: entrypoint_requires_route_and_entry
# entrypoint.sh has no defaults any more: both tasks set route access and their
# entry. The checks run before the script creates anything.
echo ""
echo "Test: entrypoint_requires_route_and_entry"
echo "--------------------------------------------"
run_entrypoint() {
  ENTRY_RC=0
  ENTRY_ERR=$(env -u SAP_BROWSER_ACCESS -u SAP_BROWSER_ENTRY "$@" bash "${ENTRYPOINT}" 2>&1 >/dev/null) || ENTRY_RC=$?
}
run_entrypoint
[[ "${ENTRY_RC}" -eq 1 ]] || fail "missing SAP_BROWSER_ACCESS must exit 1, got ${ENTRY_RC}"
grep -qF "SAP_BROWSER_ACCESS must be route." <<< "${ENTRY_ERR}" || fail "unexpected message: ${ENTRY_ERR}"
run_entrypoint SAP_BROWSER_ACCESS=port-forward SAP_BROWSER_ENTRY=hcp-pipeline.mjs
[[ "${ENTRY_RC}" -eq 1 ]] || fail "port-forward access must exit 1, got ${ENTRY_RC}"
grep -qF "SAP_BROWSER_ACCESS must be route." <<< "${ENTRY_ERR}" || fail "unexpected message: ${ENTRY_ERR}"
run_entrypoint SAP_BROWSER_ACCESS=route
[[ "${ENTRY_RC}" -eq 1 ]] || fail "missing SAP_BROWSER_ENTRY must exit 1, got ${ENTRY_RC}"
grep -qF "SAP_BROWSER_ENTRY must name an .mjs file in the helper directory." <<< "${ENTRY_ERR}" || fail "unexpected message: ${ENTRY_ERR}"
run_entrypoint SAP_BROWSER_ACCESS=route SAP_BROWSER_ENTRY=../x.mjs
[[ "${ENTRY_RC}" -eq 1 ]] || fail "an entry outside the helper directory must exit 1, got ${ENTRY_RC}"
echo "✅ PASS: entrypoint_requires_route_and_entry"

echo ""
echo "============================================"
echo "✅ All HCP SAP browser wiring tests passed"
echo "============================================"
