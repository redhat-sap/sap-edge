#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "============================================"
echo "Test: two-pass restricted-resources wiring"
echo "============================================"

# An EIC restricted-resources zip can only be downloaded after the Edge Node is
# registered with the kubeconfig the pipeline generates, so no pipeline may
# apply all bundles at once. Every pipeline below follows the ROKS shape
# (test_roks_two_pass_wiring.sh): ELM zip wait → apply-rbac-elm → ELM namespace
# labels, mesh, kubeconfig → EIC zip wait → apply-rbac-eic → EIC namespace
# labels and mesh → monitoring → ELM/EIC approval.
python3 -I - ../../.tekton <<'PY'
import glob
import os
import sys

import yaml

ROOT = sys.argv[1]
EXAMPLES = os.path.join(os.path.dirname(ROOT), ".tekton-examples")
ELM = "$(params.elmRestrictedResourcesComponents)"
EIC = "$(params.eicRestrictedResourcesComponents)"
UPLOAD_PLAN = "$(tasks.prepare-restricted-resources-prefix.results.uploadPlan)"
KUBECONFIG_SECRET = "edgelm-kubeconfig-generated-$(params.hostedClusterName)"

# Per pipeline: the two waits with the folders their instructions must name,
# the runAfter of every task of the two passes, and the run files with the
# component values they must pass.
SPECS = {
    "hcp-ossm3-multi-stack-validation-pipeline": {
        "elm_default": "elm-1 elm-2",
        "eic_default": "edge-icell-1 edge-icell-2",
        "waits": {
            "wait-elm-zips": (ELM, ("elm-1/", "elm-2/"), ()),
            "wait-eic-zips": (EIC, ("edge-icell-1/", "edge-icell-2/"),
                              (f"{KUBECONFIG_SECRET}-1", f"{KUBECONFIG_SECRET}-2")),
        },
        "run_after": {
            "wait-elm-zips": {"prepare-restricted-resources-prefix"},
            "apply-rbac-elm": {"verify-operators", "wait-elm-zips"},
            "configure-multi-stack-mesh": {"apply-rbac-elm"},
            "prepare-namespaces-multi-stack": {"configure-multi-stack-mesh"},
            "stack1-generate-sa-based-kubeconfig": {"prepare-namespaces-multi-stack"},
            "stack2-generate-sa-based-kubeconfig": {"prepare-namespaces-multi-stack"},
            # Deploying EIC in ELM needs the credentials
            "wait-eic-zips": {"cell1-get-all-accesses", "cell2-get-all-accesses"},
            "apply-rbac-eic": {"wait-eic-zips"},
            "prepare-namespaces-multi-stack-eic": {"apply-rbac-eic"},
            "enable-monitoring": {"prepare-namespaces-multi-stack-eic"},
            "approval-elm-eic-iflow-deployed": {"prepare-namespaces-multi-stack-eic", "enable-monitoring"},
        },
        "task_refs": {"prepare-namespaces-multi-stack-eic": "ossm3-prepare-namespaces-multi-stack"},
        "run_files": {
            "hcp-ossm3-multi-stack-validation-run.yaml": ("elm-1 elm-2", "edge-icell-1 edge-icell-2"),
        },
    },
    "hcp-ossm3-dedicated-validation-pipeline": {
        "elm_default": "elm",
        "eic_default": "edge-icell-1 edge-icell-2",
        "waits": {
            "wait-elm-zip": (ELM, ("elm/",), ()),
            "wait-eic-zips": (EIC, ("edge-icell-1/", "edge-icell-2/"), (KUBECONFIG_SECRET,)),
        },
        "run_after": {
            "wait-elm-zip": {"prepare-restricted-resources-prefix"},
            "apply-rbac-elm": {"verify-operators", "wait-elm-zip"},
            "prepare-namespaces": {"apply-rbac-elm"},
            "configure-mesh": {"prepare-namespaces"},
            "generate-sa-based-kubeconfig": {"configure-mesh"},
            # cell2-get-all-accesses skipped by cellCount=1 does not block
            "wait-eic-zips": {"cell1-get-all-accesses", "cell2-get-all-accesses"},
            "apply-rbac-eic": {"wait-eic-zips"},
            "prepare-namespaces-eic": {"apply-rbac-eic"},
            "configure-mesh-eic": {"prepare-namespaces-eic"},
            "enable-monitoring": {"configure-mesh-eic"},
            "approval-elm-eic-iflow-deployed": {"configure-mesh-eic", "enable-monitoring"},
        },
        "task_refs": {
            "prepare-namespaces-eic": "ossm3-prepare-namespaces-dedicated",
            "configure-mesh-eic": "ossm3-configure-dedicated-mesh",
        },
        "run_files": {
            "hcp-ossm3-dedicated-validation-run.yaml": ("elm", "edge-icell-1 edge-icell-2"),
            "hcp-ossm3-dedicated-proxy-validation-run.yaml": ("elm", "edge-icell-1"),
        },
    },
}

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def task_param(task, name):
    for p in task.get("params", []):
        if p["name"] == name:
            return p["value"]
    return None


def load(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


pipelines = {}
for path in sorted(glob.glob(os.path.join(ROOT, "pipelines", "*.yaml"))):
    doc = load(path)
    pipelines[doc["metadata"]["name"]] = doc["spec"]

for name, spec in SPECS.items():
    label = name.replace("-validation-pipeline", "")
    pipeline = pipelines.get(name)
    check(pipeline is not None, f"{label}: pipeline not found")
    if pipeline is None:
        continue
    params = {p["name"]: p for p in pipeline["params"]}
    tasks = {t["name"]: t for t in pipeline["tasks"]}

    check("restrictedResourcesComponents" not in params,
          f"{label}: restrictedResourcesComponents must be split into elm-/eicRestrictedResourcesComponents")
    check(params.get("elmRestrictedResourcesComponents", {}).get("default") == spec["elm_default"],
          f"{label}: elmRestrictedResourcesComponents default must be {spec['elm_default']!r}")
    check(params.get("eicRestrictedResourcesComponents", {}).get("default") == spec["eic_default"],
          f"{label}: eicRestrictedResourcesComponents default must be {spec['eic_default']!r}")
    for gone in ("approval-upload-restricted-resources", "apply-rbac"):
        check(gone not in tasks, f"{label}: {gone} must be replaced by the two passes")

    # The prefix task creates the folders of both passes and never archives
    # (a re-run reuses the zips already uploaded).
    prefix = tasks.get("prepare-restricted-resources-prefix", {})
    check(task_param(prefix, "components") == f"{ELM} {EIC}",
          f"{label}: prepare-restricted-resources-prefix must create the ELM and the EIC folders")
    check(task_param(prefix, "archiveExisting") is None,
          f"{label}: prepare-restricted-resources-prefix must not archive earlier zips")

    for task_name, (components, folders, secrets) in spec["waits"].items():
        task = tasks.get(task_name, {})
        check(task.get("taskRef", {}).get("name") == "ossm3-wait-for-restricted-resources",
              f"{label}: {task_name} must use ossm3-wait-for-restricted-resources (a task, not an approval)")
        check(task_param(task, "s3Prefix") == "$(params.s3Prefix)", f"{label}: {task_name} s3Prefix must be $(params.s3Prefix)")
        check(task_param(task, "components") == components, f"{label}: {task_name} components must be {components}")
        instructions = task_param(task, "instructions") or ""
        for needle in folders + secrets:
            check(needle in instructions, f"{label}: {task_name} instructions must name {needle}")
        check(instructions.strip().endswith(UPLOAD_PLAN), f"{label}: {task_name} instructions must end with {UPLOAD_PLAN}")

    for task_name, components in (("apply-rbac-elm", ELM), ("apply-rbac-eic", EIC)):
        task = tasks.get(task_name, {})
        check(task.get("taskRef", {}).get("name") == "ossm3-download-and-apply-rbac",
              f"{label}: {task_name} must use ossm3-download-and-apply-rbac")
        check(task_param(task, "requiredComponents") == components,
              f"{label}: {task_name} requiredComponents must be {components}")

    for task_name, run_after in spec["run_after"].items():
        task = tasks.get(task_name)
        check(task is not None, f"{label}: {task_name} must exist")
        if task is not None:
            got = set(task.get("runAfter", []))
            check(got == run_after, f"{label}: {task_name} runAfter must be {sorted(run_after)}, got {sorted(got)}")

    for task_name, ref in spec["task_refs"].items():
        check(tasks.get(task_name, {}).get("taskRef", {}).get("name") == ref,
              f"{label}: {task_name} must re-run {ref}")

    # Run files pass the two component lists and nothing stale; the active
    # copy in .tekton/ (if any) must match the example.
    for run_file, (elm, eic) in spec["run_files"].items():
        example = os.path.join(EXAMPLES, run_file)
        active = os.path.join(ROOT, run_file)
        if os.path.exists(active):
            with open(active, "rb") as a, open(example, "rb") as e:
                check(a.read() == e.read(), f"{active} and {example} must be identical")
        run_params = {p["name"]: p["value"] for p in load(example)["spec"]["params"]}
        check(run_params.get("elmRestrictedResourcesComponents") == elm,
              f"{run_file}: elmRestrictedResourcesComponents must be {elm!r}")
        check(run_params.get("eicRestrictedResourcesComponents") == eic,
              f"{run_file}: eicRestrictedResourcesComponents must be {eic!r}")
        check("restrictedResourcesComponents" not in run_params,
              f"{run_file}: restrictedResourcesComponents is no longer a pipeline param")

# No pipeline may still apply restricted resources in one pass
NOT_YET_TWO_PASS = {
    "hcp-ossm3-validation-pipeline",
    "aro-eic-full-test-pipeline",
    "rosa-eic-full-test-pipeline",
}
for name, pipeline in pipelines.items():
    if name in NOT_YET_TWO_PASS:
        continue
    for task in pipeline["tasks"]:
        if task.get("taskRef", {}).get("name") == "ossm3-download-and-apply-rbac":
            check(task["name"] in ("apply-rbac-elm", "apply-rbac-eic"),
                  f"{name}: {task['name']} applies restricted resources outside the two passes")

if failures:
    for f in failures:
        print(f"❌ FAIL: {f}")
    sys.exit(1)
print(f"✅ PASS: two-pass restricted-resources wiring ({len(SPECS)} pipelines)")
PY

echo ""
echo "✅ ALL TESTS PASSED"
