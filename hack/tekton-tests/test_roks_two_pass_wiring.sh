#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "============================================"
echo "Test: ROKS two-pass apply wiring"
echo "============================================"

# ROKS pipeline two-pass apply invariants: ELM zip wait → apply-rbac-elm →
# generate SA kubeconfig → EIC zip wait → apply-rbac-eic → re-apply mesh labels.
python3 -I - ../../.tekton/pipelines/roks-eic-full-test-pipeline.yaml \
  ../../.tekton/pipelines/hcp-*.yaml <<'PY'
import sys
import yaml

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load(path):
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    spec = doc["spec"]
    params = {p["name"]: p for p in spec["params"]}
    tasks = {t["name"]: t for t in spec["tasks"]}
    tasks.update({t["name"]: t for t in spec.get("finally", [])})
    return doc["metadata"]["name"], params, tasks


def task_param(task, name):
    for p in task.get("params", []):
        if p["name"] == name:
            return p["value"]
    return None


def run_after_set(task):
    return set(task.get("runAfter", []))


# ROKS pipeline
roks_path = sys.argv[1]
name, params, tasks = load(roks_path)

# No approval-upload-restricted-resources task
check("approval-upload-restricted-resources" not in tasks,
      "ROKS: approval-upload-restricted-resources must be deleted")

# prepare-restricted-resources-prefix has archiveExisting: "true"
prefix_task = tasks.get("prepare-restricted-resources-prefix")
check(prefix_task is not None, "ROKS: prepare-restricted-resources-prefix must exist")
if prefix_task:
    check(task_param(prefix_task, "archiveExisting") == "true",
          "ROKS: prepare-restricted-resources-prefix must have archiveExisting: \"true\"")

# wait-elm-zip
elm_wait = tasks.get("wait-elm-zip")
check(elm_wait is not None, "ROKS: wait-elm-zip must exist")
if elm_wait:
    check(run_after_set(elm_wait) == {"prepare-restricted-resources-prefix"},
          f"ROKS: wait-elm-zip runAfter must be [prepare-restricted-resources-prefix], got {run_after_set(elm_wait)}")
    check(task_param(elm_wait, "s3Prefix") == "restricted-resources/$(params.clusterName)/",
          "ROKS: wait-elm-zip s3Prefix must be restricted-resources/$(params.clusterName)/")
    check(task_param(elm_wait, "components") == "elm",
          "ROKS: wait-elm-zip components must be \"elm\"")
    instructions = task_param(elm_wait, "instructions")
    check(instructions and "Edge Lifecycle Management" in instructions and "elm/" in instructions,
          "ROKS: wait-elm-zip instructions must mention ELM and elm/ folder")

# apply-rbac-elm (renamed from apply-rbac)
check("apply-rbac" not in tasks, "ROKS: apply-rbac must be renamed to apply-rbac-elm")
elm_apply = tasks.get("apply-rbac-elm")
check(elm_apply is not None, "ROKS: apply-rbac-elm must exist")
if elm_apply:
    check(run_after_set(elm_apply) == {"verify-operators", "wait-elm-zip"},
          f"ROKS: apply-rbac-elm runAfter must be [verify-operators, wait-elm-zip], got {run_after_set(elm_apply)}")
    check(task_param(elm_apply, "requiredComponents") == "elm",
          "ROKS: apply-rbac-elm requiredComponents must be \"elm\"")
    check(task_param(elm_apply, "s3Prefix") == "restricted-resources/$(params.clusterName)/",
          "ROKS: apply-rbac-elm s3Prefix must be restricted-resources/$(params.clusterName)/")

# prepare-namespaces depends on apply-rbac-elm
prep_ns = tasks.get("prepare-namespaces")
check(prep_ns is not None, "ROKS: prepare-namespaces must exist")
if prep_ns:
    check(run_after_set(prep_ns) == {"apply-rbac-elm"},
          f"ROKS: prepare-namespaces runAfter must be [apply-rbac-elm], got {run_after_set(prep_ns)}")

# configure-mesh depends on prepare-namespaces (unchanged)
mesh = tasks.get("configure-mesh")
check(mesh is not None, "ROKS: configure-mesh must exist")
if mesh:
    check(run_after_set(mesh) == {"prepare-namespaces"},
          f"ROKS: configure-mesh runAfter must be [prepare-namespaces], got {run_after_set(mesh)}")

# generate-sa-based-kubeconfig depends on configure-mesh (unchanged)
gen_kc = tasks.get("generate-sa-based-kubeconfig")
check(gen_kc is not None, "ROKS: generate-sa-based-kubeconfig must exist")
if gen_kc:
    check(run_after_set(gen_kc) == {"configure-mesh"},
          f"ROKS: generate-sa-based-kubeconfig runAfter must be [configure-mesh], got {run_after_set(gen_kc)}")

# wait-eic-zip
eic_wait = tasks.get("wait-eic-zip")
check(eic_wait is not None, "ROKS: wait-eic-zip must exist")
if eic_wait:
    check(run_after_set(eic_wait) == {"generate-sa-based-kubeconfig"},
          f"ROKS: wait-eic-zip runAfter must be [generate-sa-based-kubeconfig], got {run_after_set(eic_wait)}")
    check(task_param(eic_wait, "s3Prefix") == "restricted-resources/$(params.clusterName)/",
          "ROKS: wait-eic-zip s3Prefix must be restricted-resources/$(params.clusterName)/")
    check(task_param(eic_wait, "components") == "edge-icell",
          "ROKS: wait-eic-zip components must be \"edge-icell\"")
    instructions = task_param(eic_wait, "instructions")
    check(instructions and "Edge Integration Cell" in instructions and "edge-icell/" in instructions,
          "ROKS: wait-eic-zip instructions must mention EIC and edge-icell/ folder")

# apply-rbac-eic
eic_apply = tasks.get("apply-rbac-eic")
check(eic_apply is not None, "ROKS: apply-rbac-eic must exist")
if eic_apply:
    check(run_after_set(eic_apply) == {"wait-eic-zip"},
          f"ROKS: apply-rbac-eic runAfter must be [wait-eic-zip], got {run_after_set(eic_apply)}")
    check(task_param(eic_apply, "requiredComponents") == "edge-icell",
          "ROKS: apply-rbac-eic requiredComponents must be \"edge-icell\"")
    check(task_param(eic_apply, "s3Prefix") == "restricted-resources/$(params.clusterName)/",
          "ROKS: apply-rbac-eic s3Prefix must be restricted-resources/$(params.clusterName)/")

# prepare-namespaces-eic
prep_ns_eic = tasks.get("prepare-namespaces-eic")
check(prep_ns_eic is not None, "ROKS: prepare-namespaces-eic must exist")
if prep_ns_eic:
    check(run_after_set(prep_ns_eic) == {"apply-rbac-eic"},
          f"ROKS: prepare-namespaces-eic runAfter must be [apply-rbac-eic], got {run_after_set(prep_ns_eic)}")

# configure-mesh-eic
mesh_eic = tasks.get("configure-mesh-eic")
check(mesh_eic is not None, "ROKS: configure-mesh-eic must exist")
if mesh_eic:
    check(run_after_set(mesh_eic) == {"prepare-namespaces-eic"},
          f"ROKS: configure-mesh-eic runAfter must be [prepare-namespaces-eic], got {run_after_set(mesh_eic)}")

# approval-elm-eic-iflow-deployed depends on configure-mesh-eic and registry-access
approval = tasks.get("approval-elm-eic-iflow-deployed")
check(approval is not None, "ROKS: approval-elm-eic-iflow-deployed must exist")
if approval:
    check(run_after_set(approval) == {"configure-mesh-eic", "registry-access"},
          f"ROKS: approval-elm-eic-iflow-deployed runAfter must be [configure-mesh-eic, registry-access], got {run_after_set(approval)}")
    description = task_param(approval, "description")
    check(description and "registration and EIC deployment" in description,
          "ROKS: approval-elm-eic-iflow-deployed description must mention registration and EIC deployment")

# HCP pipelines must not set archiveExisting
for hcp_path in sys.argv[2:]:
    name, params, tasks = load(hcp_path)
    for task_name, task in tasks.items():
        archive_param = task_param(task, "archiveExisting")
        check(archive_param is None,
              f"{name}: {task_name} must not set archiveExisting (got {archive_param})")

if failures:
    for f in failures:
        print(f"❌ FAIL: {f}")
    sys.exit(1)
print("✅ PASS: ROKS two-pass apply wiring")
PY

echo ""
echo "✅ ALL TESTS PASSED"
