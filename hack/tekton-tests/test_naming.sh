#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "============================================"
echo "Test: pipeline and run file naming"
echo "============================================"

# Naming rule (.tekton/README.md, "Pipelines"):
#   .tekton/pipelines/<name>-pipeline.yaml   metadata.name <name>-pipeline
#   <run dir>/<name>[-<variant>]-run.yaml    pipelineRef <name>-pipeline,
#                                            generateName <name>[-<variant>]-pr{{ pull_request_number }}-
#   "ossm3" in <name>  <=>  restricted access (the pipeline applies SAP's
#                           restricted-resources zips)
python3 -I - ../../.tekton <<'PY'
import glob
import os
import sys

import yaml

ROOT = sys.argv[1]
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load_all(path):
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if d]


pipelines = {}
for path in sorted(glob.glob(os.path.join(ROOT, "pipelines", "*.yaml"))):
    for doc in load_all(path):
        if doc.get("kind") != "Pipeline":
            continue
        name = doc["metadata"]["name"]
        pipelines[name] = doc
        check(os.path.basename(path) == f"{name}.yaml", f"{path}: file name must be {name}.yaml")
        check(name.endswith("-pipeline"), f"{name}: pipeline names end in -pipeline")
        restricted = any(t.get("taskRef", {}).get("name") == "ossm3-download-and-apply-rbac"
                         for t in doc["spec"]["tasks"])
        check(("ossm3" in name) == restricted,
              f"{name}: 'ossm3' in the name must mean restricted access (applies restricted-resources: {restricted})")

run_files = sorted(glob.glob(os.path.join(ROOT, "*-run.yaml"))
                   + glob.glob(os.path.join(os.path.dirname(ROOT), ".tekton-examples", "*-run.yaml")))
check(run_files, "no run files found")
for path in run_files:
    for doc in load_all(path):
        if doc.get("kind") != "PipelineRun":
            continue
        pipeline = doc["spec"]["pipelineRef"]["name"]
        check(pipeline in pipelines, f"{path}: pipelineRef {pipeline} does not exist")
        stem = pipeline[: -len("-pipeline")] if pipeline.endswith("-pipeline") else pipeline
        file_stem = os.path.basename(path)[: -len("-run.yaml")]
        check(file_stem == stem or file_stem.startswith(f"{stem}-"),
              f"{path}: file name must be {stem}[-<variant>]-run.yaml (pipelineRef {pipeline})")
        generate_name = doc["metadata"].get("generateName", "")
        check(generate_name == f"{file_stem}-pr{{{{ pull_request_number }}}}-",
              f"{path}: generateName must be {file_stem}-pr{{{{ pull_request_number }}}}-, got {generate_name!r}")

if failures:
    for f in failures:
        print(f"❌ FAIL: {f}")
    sys.exit(1)
print(f"✅ PASS: naming ({len(pipelines)} pipelines, {len(run_files)} run files)")
PY

echo ""
echo "✅ ALL TESTS PASSED"
