#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "============================================"
echo "Test: multi-EIC pipeline wiring"
echo "============================================"

# Topology A (per-cell) and B (multi-stack) pipeline invariants that the
# generic checker does not cover.
python3 -I - ../../.tekton/pipelines/hcp-ossm3-dedicated-validation-pipeline.yaml \
  ../../.tekton/pipelines/hcp-ossm3-multi-stack-validation-pipeline.yaml <<'PY'
import sys
import yaml

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load(path):
    with open(path, encoding="utf-8") as f:
        spec = yaml.safe_load(f)["spec"]
    params = {p["name"]: p for p in spec["params"]}
    tasks = {t["name"]: t for t in spec["tasks"]}
    tasks.update({t["name"]: t for t in spec.get("finally", [])})
    return params, tasks


def task_param(task, name):
    for p in task.get("params", []):
        if p["name"] == name:
            return p["value"]
    return None


for label, path in (("A", sys.argv[1]), ("B", sys.argv[2])):
    params, tasks = load(path)
    # Both Redis cells apply the same cluster-scoped SCC: serialize them.
    check("cell1-deploy-redis" in tasks["cell2-deploy-redis"].get("runAfter", []),
          f"{label}: cell2-deploy-redis must runAfter cell1-deploy-redis")
    # Valkey is namespaced only and stays parallel.
    check("cell1-deploy-valkey" not in tasks["cell2-deploy-valkey"].get("runAfter", []),
          f"{label}: cell2-deploy-valkey should stay parallel to cell1-deploy-valkey")
    for n in ("1", "2"):
        check(task_param(tasks[f"cell{n}-get-all-accesses"], "instance") == f"eic-{n}",
              f"{label}: cell{n}-get-all-accesses must use instance eic-{n}")

    if label == "A":
        for n in ("1", "2"):
            check(task_param(tasks[f"cell{n}-get-all-accesses"], "elmKubeconfigFile") is None,
                  f"A: cell{n}-get-all-accesses must use the shared edgelm-kubeconfig (task default)")
        comment = task_param(tasks["update-jira-test-results"], "comment")
        cell2_lines = [line.strip() for line in comment.split("\n") if line.strip().startswith("* Cell 2: cell2-test-")]
        check(len(cell2_lines) == 3, f"A: expected 3 cell-2 test lines in the Jira comment, got {len(cell2_lines)}")
        for line in cell2_lines:
            check(line.endswith("(skipped when cellCount=1)"),
                  f"A: Jira cell-2 test line not tagged as skipped when cellCount=1: {line[:60]}")
        # The two-pass wiring and the component defaults: test_two_pass_wiring.sh
        check("eicRestrictedResourcesComponents without edge-icell-2" in params["cellCount"]["description"],
              "A: cellCount description must say that 1 needs eicRestrictedResourcesComponents without edge-icell-2")
    else:
        for n in ("1", "2"):
            check(task_param(tasks[f"cell{n}-get-all-accesses"], "elmKubeconfigFile") == f"edgelm-{n}-kubeconfig",
                  f"B: cell{n}-get-all-accesses must store edgelm-{n}-kubeconfig")

if failures:
    for f in failures:
        print(f"❌ FAIL: {f}")
    sys.exit(1)
print("✅ PASS: multi-EIC pipeline wiring")
PY

echo ""
echo "✅ ALL TESTS PASSED"
