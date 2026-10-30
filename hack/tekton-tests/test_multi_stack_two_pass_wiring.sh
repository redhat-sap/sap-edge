#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "============================================"
echo "Test: multi-stack two-pass apply wiring"
echo "============================================"

# Topology B two-pass apply invariants: ELM zips wait → apply-rbac-elm → meshes,
# namespace labels and per-stack kubeconfigs → backing services → EIC zips wait
# → apply-rbac-eic → EIC namespace labels → monitoring → ELM/EIC approval.
# The EIC zips can only be downloaded after the Edge Nodes are registered with
# the generated kubeconfigs, so one apply of all folders cannot work.
python3 -I - ../../.tekton/pipelines/hcp-ossm3-multi-stack-validation-pipeline.yaml \
  ../../.tekton/hcp-ossm3-multi-stack-validation-run.yaml \
  ../../.tekton-examples/hcp-ossm3-multi-stack-validation-run.yaml <<'PY'
import sys
import yaml

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def task_param(task, name):
    for p in task.get("params", []):
        if p["name"] == name:
            return p["value"]
    return None


def run_after_set(task):
    return set(task.get("runAfter", []))


with open(sys.argv[1], encoding="utf-8") as f:
    spec = yaml.safe_load(f)["spec"]
params = {p["name"]: p for p in spec["params"]}
tasks = {t["name"]: t for t in spec["tasks"]}

ELM = "$(params.elmRestrictedResourcesComponents)"
EIC = "$(params.eicRestrictedResourcesComponents)"
UPLOAD_PLAN = "$(tasks.prepare-restricted-resources-prefix.results.uploadPlan)"

check("restrictedResourcesComponents" not in params,
      "B: restrictedResourcesComponents must be split into elm-/eicRestrictedResourcesComponents")
for gone in ("approval-upload-restricted-resources", "apply-rbac"):
    check(gone not in tasks, f"B: {gone} must be replaced by the two passes")

# The prefix task creates the folders of both passes and never archives
# (a re-run of the same PR reuses the zips already uploaded).
prefix = tasks.get("prepare-restricted-resources-prefix", {})
check(task_param(prefix, "components") == f"{ELM} {EIC}",
      "B: prepare-restricted-resources-prefix must create the ELM and the EIC folders")
check(task_param(prefix, "archiveExisting") is None,
      "B: prepare-restricted-resources-prefix must not archive earlier zips")


def check_wait(name, components, run_after, folders):
    task = tasks.get(name)
    check(task is not None, f"B: {name} must exist")
    if not task:
        return
    check(task["taskRef"]["name"] == "ossm3-wait-for-restricted-resources",
          f"B: {name} must use ossm3-wait-for-restricted-resources (a task, not an approval)")
    check(run_after_set(task) == run_after,
          f"B: {name} runAfter must be {sorted(run_after)}, got {sorted(run_after_set(task))}")
    check(task_param(task, "s3Prefix") == "$(params.s3Prefix)", f"B: {name} s3Prefix must be $(params.s3Prefix)")
    check(task_param(task, "components") == components, f"B: {name} components must be {components}")
    instructions = task_param(task, "instructions") or ""
    for folder in folders:
        check(folder in instructions, f"B: {name} instructions must name the {folder} folder")
    check(instructions.strip().endswith(UPLOAD_PLAN), f"B: {name} instructions must end with {UPLOAD_PLAN}")


def check_apply(name, components, run_after):
    task = tasks.get(name)
    check(task is not None, f"B: {name} must exist")
    if not task:
        return
    check(task["taskRef"]["name"] == "ossm3-download-and-apply-rbac",
          f"B: {name} must use ossm3-download-and-apply-rbac")
    check(run_after_set(task) == run_after,
          f"B: {name} runAfter must be {sorted(run_after)}, got {sorted(run_after_set(task))}")
    check(task_param(task, "requiredComponents") == components,
          f"B: {name} requiredComponents must be {components}")


def check_run_after(name, run_after):
    task = tasks.get(name)
    check(task is not None, f"B: {name} must exist")
    if task:
        check(run_after_set(task) == run_after,
              f"B: {name} runAfter must be {sorted(run_after)}, got {sorted(run_after_set(task))}")


# First pass: ELM bundles of both Edge Nodes
check_wait("wait-elm-zips", ELM, {"prepare-restricted-resources-prefix"}, ("elm-1/", "elm-2/"))
check_apply("apply-rbac-elm", ELM, {"verify-operators", "wait-elm-zips"})
check_run_after("configure-multi-stack-mesh", {"apply-rbac-elm"})
check_run_after("prepare-namespaces-multi-stack", {"configure-multi-stack-mesh"})
for n in ("1", "2"):
    check_run_after(f"stack{n}-generate-sa-based-kubeconfig", {"prepare-namespaces-multi-stack"})
    # Deploying EIC in ELM needs the credentials, so they come before the EIC wait;
    # monitoring needs the EIC namespaces, so the credentials no longer wait for it.
    check("enable-monitoring" not in run_after_set(tasks[f"cell{n}-get-all-accesses"]),
          f"B: cell{n}-get-all-accesses must not wait for enable-monitoring (it runs after the EIC pass)")

# Second pass: EIC bundles, after registration and EIC deployment in ELM
check_wait("wait-eic-zips", EIC, {"cell1-get-all-accesses", "cell2-get-all-accesses"},
           ("edge-icell-1/", "edge-icell-2/"))
eic_instructions = task_param(tasks.get("wait-eic-zips", {}), "instructions") or ""
for n in ("1", "2"):
    secret = f"edgelm-kubeconfig-generated-$(params.hostedClusterName)-{n}"
    check(secret in eic_instructions, f"B: wait-eic-zips instructions must name the kubeconfig Secret {secret}")
check_apply("apply-rbac-eic", EIC, {"wait-eic-zips"})
eic_ns = tasks.get("prepare-namespaces-multi-stack-eic", {})
check(eic_ns.get("taskRef", {}).get("name") == "ossm3-prepare-namespaces-multi-stack",
      "B: prepare-namespaces-multi-stack-eic must re-run ossm3-prepare-namespaces-multi-stack")
check_run_after("prepare-namespaces-multi-stack-eic", {"apply-rbac-eic"})
# The NetworkPolicies go only into namespaces that exist, so after the EIC pass
check_run_after("enable-monitoring", {"prepare-namespaces-multi-stack-eic"})
check_run_after("approval-elm-eic-iflow-deployed", {"prepare-namespaces-multi-stack-eic", "enable-monitoring"})

# Both run files pass the two component lists and nothing stale
for run_path in sys.argv[2:]:
    with open(run_path, encoding="utf-8") as f:
        run_params = {p["name"]: p["value"] for p in yaml.safe_load(f)["spec"]["params"]}
    check(run_params.get("elmRestrictedResourcesComponents") == "elm-1 elm-2",
          f"{run_path}: elmRestrictedResourcesComponents must be 'elm-1 elm-2'")
    check(run_params.get("eicRestrictedResourcesComponents") == "edge-icell-1 edge-icell-2",
          f"{run_path}: eicRestrictedResourcesComponents must be 'edge-icell-1 edge-icell-2'")
    check("restrictedResourcesComponents" not in run_params,
          f"{run_path}: restrictedResourcesComponents is no longer a pipeline param")

if failures:
    for f in failures:
        print(f"❌ FAIL: {f}")
    sys.exit(1)
print("✅ PASS: multi-stack two-pass apply wiring")
PY

echo ""
echo "✅ ALL TESTS PASSED"
