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
# (test_roks_two_pass_wiring.sh): ELM zip wait → apply-elm-resources → ELM namespace
# labels, mesh, kubeconfig → EIC zip wait → apply-eic-resources → EIC namespace
# labels and mesh → monitoring → ELM/EIC approval.
python3 -I - ../../.tekton <<'PY'
import glob
import os
import sys

import yaml

ROOT = sys.argv[1]
EXAMPLES = os.path.join(os.path.dirname(ROOT), ".tekton-examples")
ELM = "$(params.elmZipFolders)"
EIC = "$(params.eicZipFolders)"
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
            "wait-elm-zip": (ELM, ("elm-1/", "elm-2/"), ()),
            "wait-eic-zip": (EIC, ("edge-icell-1/", "edge-icell-2/"),
                              (f"{KUBECONFIG_SECRET}-1", f"{KUBECONFIG_SECRET}-2")),
        },
        "run_after": {
            "wait-elm-zip": {"prepare-restricted-resources-prefix"},
            "apply-elm-resources": {"verify-operators", "wait-elm-zip"},
            "configure-multi-stack-mesh": {"apply-elm-resources"},
            "prepare-namespaces-multi-stack": {"configure-multi-stack-mesh"},
            "stack1-generate-sa-based-kubeconfig": {"prepare-namespaces-multi-stack"},
            "stack2-generate-sa-based-kubeconfig": {"prepare-namespaces-multi-stack"},
            # Deploying EIC in ELM needs the credentials
            "wait-eic-zip": {"cell1-get-all-accesses", "cell2-get-all-accesses"},
            "apply-eic-resources": {"wait-eic-zip"},
            "prepare-namespaces-multi-stack-eic": {"apply-eic-resources"},
            "enable-monitoring": {"prepare-namespaces-multi-stack-eic"},
            "approval-elm-eic-iflow-deployed": {"prepare-namespaces-multi-stack-eic", "enable-monitoring"},
        },
        "task_refs": {"prepare-namespaces-multi-stack-eic": "ossm3-prepare-namespaces-multi-stack"},
        "run_files": {
            "hcp-ossm3-multi-stack-validation-run.yaml": {
                "elmZipFolders": "elm-1 elm-2",
                "eicZipFolders": "edge-icell-1 edge-icell-2",
            },
        },
    },
    "hcp-ossm3-dedicated-validation-pipeline": {
        "elm_default": "elm",
        "eic_default": "edge-icell-1 edge-icell-2",
        "waits": {
            "wait-elm-zip": (ELM, ("elm/",), ()),
            "wait-eic-zip": (EIC, ("edge-icell-1/", "edge-icell-2/"), (KUBECONFIG_SECRET,)),
        },
        "run_after": {
            "wait-elm-zip": {"prepare-restricted-resources-prefix"},
            "apply-elm-resources": {"verify-operators", "wait-elm-zip"},
            "prepare-namespaces": {"apply-elm-resources"},
            "configure-mesh": {"prepare-namespaces"},
            "generate-sa-based-kubeconfig": {"configure-mesh"},
            # cell2-get-all-accesses skipped by cellCount=1 does not block
            "wait-eic-zip": {"cell1-get-all-accesses", "cell2-get-all-accesses"},
            "apply-eic-resources": {"wait-eic-zip"},
            "prepare-namespaces-eic": {"apply-eic-resources"},
            "configure-mesh-eic": {"prepare-namespaces-eic"},
            "enable-monitoring": {"configure-mesh-eic"},
            "approval-elm-eic-iflow-deployed": {"configure-mesh-eic", "enable-monitoring"},
        },
        "task_refs": {
            "prepare-namespaces-eic": "ossm3-prepare-namespaces-dedicated",
            "configure-mesh-eic": "ossm3-configure-dedicated-mesh",
        },
        "run_files": {
            "hcp-ossm3-dedicated-validation-run.yaml": {
                "elmZipFolders": "elm",
                "eicZipFolders": "edge-icell-1 edge-icell-2",
            },
            "hcp-ossm3-dedicated-validation-proxy-run.yaml": {
                "elmZipFolders": "elm",
                "eicZipFolders": "edge-icell-1",
            },
        },
    },
    "hcp-ossm3-validation-pipeline": {
        "elm_default": "elm",
        "eic_default": "edge-icell",
        "waits": {
            "wait-elm-zip": (ELM, ("elm/",), ()),
            "wait-eic-zip": (EIC, ("edge-icell/",), (KUBECONFIG_SECRET,)),
        },
        "run_after": {
            "wait-elm-zip": {"prepare-restricted-resources-prefix"},
            "apply-elm-resources": {"verify-operators", "wait-elm-zip"},
            "prepare-namespaces": {"apply-elm-resources"},
            "configure-mesh": {"prepare-namespaces"},
            "generate-sa-based-kubeconfig": {"configure-mesh"},
            # The optional browser session drives registration; skipped when disabled
            "wait-eic-zip": {"get-all-accesses", "sap-browser"},
            "apply-eic-resources": {"wait-eic-zip"},
            "prepare-namespaces-eic": {"apply-eic-resources"},
            "configure-mesh-eic": {"prepare-namespaces-eic"},
            "enable-monitoring": {"configure-mesh-eic"},
            "approval-elm-eic-iflow-deployed": {"configure-mesh-eic", "enable-monitoring"},
        },
        "task_refs": {
            "prepare-namespaces-eic": "ossm3-prepare-namespaces",
            "configure-mesh-eic": "ossm3-configure-mesh",
        },
        "run_files": {
            # One folder per cluster, never the shared flat restricted-resources/
            "hcp-ossm3-validation-run.yaml": {
                "s3Prefix": "restricted-resources/hcp-ossm-eic-pr{{ pull_request_number }}/",
            },
        },
    },
    "aro-eic-ossm3-pipeline": {
        "elm_default": "elm",
        "eic_default": "edge-icell",
        "waits": {
            "wait-elm-zip": (ELM, ("elm/",), ()),
            "wait-eic-zip": (EIC, ("edge-icell/",), ("edgelm-kubeconfig-generated-$(params.aroClusterName)",)),
        },
        "run_after": {
            "wait-elm-zip": {"prepare-restricted-resources-prefix"},
            "apply-elm-resources": {"verify-operators", "wait-elm-zip"},
            "prepare-namespaces": {"apply-elm-resources"},
            "configure-mesh": {"prepare-namespaces"},
            "generate-sa-based-kubeconfig": {"configure-mesh"},
            # PostgreSQL/Redis come with the cluster; ELM needs the registry
            "wait-eic-zip": {"generate-sa-based-kubeconfig", "deploy-quay"},
            "apply-eic-resources": {"wait-eic-zip"},
            "prepare-namespaces-eic": {"apply-eic-resources"},
            "configure-mesh-eic": {"prepare-namespaces-eic"},
            "approval-elm-eic-iflow-deployed": {"deploy-quay", "configure-mesh-eic"},
        },
        "task_refs": {
            "prepare-namespaces-eic": "ossm3-prepare-namespaces",
            "configure-mesh-eic": "ossm3-configure-mesh",
        },
        # skipEicValidation=true deploys no EIC: every task of the second pass
        # must be gated itself (a skipped parent does not block its dependents)
        "eic_pass_gate": ("skipEicValidation", "false"),
        "run_files": {
            "aro-eic-ossm3-run.yaml": {"s3Prefix": "restricted-resources/eic-on-ocp-demo/"},
        },
    },
    "rosa-eic-ossm3-pipeline": {
        "elm_default": "elm",
        "eic_default": "edge-icell",
        "waits": {
            "wait-elm-zip": (ELM, ("elm/",), ()),
            "wait-eic-zip": (EIC, ("edge-icell/",), ("edgelm-kubeconfig-generated-$(params.clusterName)",)),
        },
        "run_after": {
            "wait-elm-zip": {"prepare-restricted-resources-prefix"},
            "apply-elm-resources": {"verify-operators", "wait-elm-zip"},
            "prepare-namespaces": {"apply-elm-resources"},
            "configure-mesh": {"prepare-namespaces"},
            "generate-sa-based-kubeconfig": {"configure-mesh"},
            # PostgreSQL/Redis come with the cluster; ELM needs the registry
            "wait-eic-zip": {"generate-sa-based-kubeconfig", "deploy-quay"},
            "apply-eic-resources": {"wait-eic-zip"},
            "prepare-namespaces-eic": {"apply-eic-resources"},
            "configure-mesh-eic": {"prepare-namespaces-eic"},
            "approval-elm-eic-iflow-deployed": {"deploy-quay", "configure-mesh-eic"},
        },
        "task_refs": {
            "prepare-namespaces-eic": "ossm3-prepare-namespaces",
            "configure-mesh-eic": "ossm3-configure-mesh",
        },
        # skipEicValidation=true deploys no EIC: every task of the second pass
        # must be gated itself (a skipped parent does not block its dependents)
        "eic_pass_gate": ("skipEicValidation", "false"),
        "run_files": {
            "rosa-eic-ossm3-run.yaml": {"s3Prefix": "restricted-resources/rosa-ossm-pr{{ pull_request_number }}/"},
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
          f"{label}: restrictedResourcesComponents must be split into elmZipFolders and eicZipFolders")
    check(params.get("elmZipFolders", {}).get("default") == spec["elm_default"],
          f"{label}: elmZipFolders default must be {spec['elm_default']!r}")
    check(params.get("eicZipFolders", {}).get("default") == spec["eic_default"],
          f"{label}: eicZipFolders default must be {spec['eic_default']!r}")
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

    for task_name, components in (("apply-elm-resources", ELM), ("apply-eic-resources", EIC)):
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

    gate = spec.get("eic_pass_gate")
    if gate:
        param, value = gate
        for task_name in ("wait-eic-zip", "apply-eic-resources", "prepare-namespaces-eic", "configure-mesh-eic"):
            whens = tasks.get(task_name, {}).get("when", [])
            check(any(w.get("input") == f"$(params.{param})" and w.get("operator") == "in" and w.get("values") == [value]
                      for w in whens),
                  f"{label}: {task_name} must be gated by {param} in [{value}]")

    for task_name, ref in spec["task_refs"].items():
        check(tasks.get(task_name, {}).get("taskRef", {}).get("name") == ref,
              f"{label}: {task_name} must re-run {ref}")

    # Run files pass the expected values and nothing stale; the active copy in
    # .tekton/ (if any) must match the example.
    for run_file, expected in spec["run_files"].items():
        example = os.path.join(EXAMPLES, run_file)
        active = os.path.join(ROOT, run_file)
        if os.path.exists(active):
            with open(active, "rb") as a, open(example, "rb") as e:
                check(a.read() == e.read(), f"{active} and {example} must be identical")
        run_params = {p["name"]: p["value"] for p in load(example)["spec"]["params"]}
        for param, value in expected.items():
            check(run_params.get(param) == value, f"{run_file}: {param} must be {value!r}")
        check("restrictedResourcesComponents" not in run_params,
              f"{run_file}: restrictedResourcesComponents is no longer a pipeline param")

# No pipeline may still apply restricted resources in one pass
for name, pipeline in pipelines.items():
    for task in pipeline["tasks"]:
        if task.get("taskRef", {}).get("name") == "ossm3-download-and-apply-rbac":
            check(task["name"] in ("apply-elm-resources", "apply-eic-resources"),
                  f"{name}: {task['name']} applies restricted resources outside the two passes")

if failures:
    for f in failures:
        print(f"❌ FAIL: {f}")
    sys.exit(1)
print(f"✅ PASS: two-pass restricted-resources wiring ({len(SPECS)} pipelines)")
PY

echo ""
echo "✅ ALL TESTS PASSED"
