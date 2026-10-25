#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

"""
Validate Tekton pipeline wiring and references.
"""

import sys
import argparse
import re
from pathlib import Path
import yaml


# Allowlist for existing violations in pipelines not touched by this plan
# Format: (pipeline_name, rule, item)
ALLOWLIST = [
    # Pre-existing defect: ApprovalTask with when (violates memory doc; requires computed-timeout workaround)
    ("aro-edgelm-validation-pipeline", "ApprovalTask.when", "manual-approval-post-deployment"),
    ("aro-edgelm-validation-pipeline", "ApprovalTask.when", "approval-second-validation-round"),
    ("aro-eic-full-test-pipeline", "ApprovalTask.when", "approval-elm-eic-iflow-deployed"),
    ("aro-eic-full-test-pipeline", "ApprovalTask.when", "approval-second-test-round"),
    ("rosa-edgelm-validation-pipeline", "ApprovalTask.when", "manual-approval-post-deployment"),
    ("rosa-edgelm-validation-pipeline", "ApprovalTask.when", "approval-second-validation-round"),
    ("rosa-eic-full-test-pipeline", "ApprovalTask.when", "approval-elm-eic-iflow-deployed"),
    ("rosa-eic-full-test-pipeline", "ApprovalTask.when", "approval-second-test-round"),
    # Pre-existing defect: postgresAdminPassword param removed from rosa-deploy-with-eic-services task but pipeline still passes it
    ("rosa-edgelm-validation-pipeline", "param.undeclared", "deploy-rosa.postgresAdminPassword"),
    ("rosa-validation-pipeline", "param.undeclared", "deploy-rosa.postgresAdminPassword"),
    # Pre-existing defect: .tekton-examples/rosa-edgelm-validation-run.yaml passes a param its pipeline does not declare
    ("rosa-edgelm-validation-pr{{ pull_request_number }}-", "param", "pullRequestNumber"),
]


def find_tasks_dir():
    """Find the .tekton/tasks directory."""
    script_dir = Path(__file__).parent
    tasks_dir = script_dir.parent.parent / ".tekton" / "tasks"
    if not tasks_dir.exists():
        print(f"Error: Tasks directory not found: {tasks_dir}", file=sys.stderr)
        sys.exit(1)
    return tasks_dir


def load_task_definitions(tasks_dir):
    """Load all Task definitions from .tekton/tasks/*.yaml."""
    tasks = {}
    for task_file in tasks_dir.glob("*.yaml"):
        with open(task_file, "r", encoding="utf-8") as f:
            docs = list(yaml.safe_load_all(f))
            for doc in docs:
                if doc and doc.get("kind") == "Task":
                    name = doc["metadata"]["name"]
                    tasks[name] = doc
    return tasks


def check_pipeline(pipeline, tasks, cell_gates):
    """Check a single pipeline for violations."""
    violations = []
    pipeline_name = pipeline["metadata"]["name"]

    # Get pipeline params
    pipeline_params = {
        p["name"] for p in pipeline.get("spec", {}).get("params", [])
    }

    # Get pipeline tasks
    pipeline_tasks = {}
    for task in pipeline.get("spec", {}).get("tasks", []):
        pipeline_tasks[task["name"]] = task

    # Check each task
    for task_name, task in pipeline_tasks.items():
        # Check runAfter targets
        for run_after in task.get("runAfter", []):
            if run_after not in pipeline_tasks:
                if (pipeline_name, "runAfter", run_after) not in ALLOWLIST:
                    violations.append(
                        f"{pipeline_name}: task '{task_name}' runAfter references unknown task '{run_after}'"
                    )

        # Check taskRef
        task_ref = task.get("taskRef", {})
        if "kind" in task_ref:
            # ApprovalTask or other special kind
            if task_ref.get("kind") == "ApprovalTask":
                # ApprovalTasks must not have when
                if "when" in task:
                    if (pipeline_name, "ApprovalTask.when", task_name) not in ALLOWLIST:
                        violations.append(
                            f"{pipeline_name}: ApprovalTask '{task_name}' has when (not allowed)"
                        )
        elif "name" in task_ref:
            # Regular Task reference
            ref_name = task_ref["name"]
            if ref_name not in tasks:
                if (pipeline_name, "taskRef", ref_name) not in ALLOWLIST:
                    violations.append(
                        f"{pipeline_name}: task '{task_name}' references unknown Task '{ref_name}'"
                    )
            else:
                referenced_task = tasks[ref_name]
                # Check params
                task_params = {
                    p["name"]: p
                    for p in referenced_task.get("spec", {}).get("params", [])
                }
                passed_params = {
                    p["name"] for p in task.get("params", [])
                }

                # Check that every passed param is declared
                for param_name in passed_params:
                    if param_name not in task_params:
                        if (pipeline_name, "param.undeclared", f"{task_name}.{param_name}") not in ALLOWLIST:
                            violations.append(
                                f"{pipeline_name}: task '{task_name}' passes undeclared param '{param_name}' to Task '{ref_name}'"
                            )

                # Check that every required param is passed
                for param_name, param_def in task_params.items():
                    if "default" not in param_def and param_name not in passed_params:
                        if (pipeline_name, "param.required", f"{task_name}.{param_name}") not in ALLOWLIST:
                            violations.append(
                                f"{pipeline_name}: task '{task_name}' missing required param '{param_name}' for Task '{ref_name}'"
                            )

                # Check workspaces (only required workspaces must be bound)
                task_workspaces = {
                    w["name"]: w
                    for w in referenced_task.get("spec", {}).get("workspaces", [])
                }
                bound_workspaces = {
                    w["name"] for w in task.get("workspaces", [])
                }
                for ws_name, ws_def in task_workspaces.items():
                    # Only require binding if workspace is not optional
                    is_optional = ws_def.get("optional", False)
                    if not is_optional and ws_name not in bound_workspaces:
                        if (pipeline_name, "workspace", f"{task_name}.{ws_name}") not in ALLOWLIST:
                            violations.append(
                                f"{pipeline_name}: task '{task_name}' missing workspace binding '{ws_name}' for Task '{ref_name}'"
                            )
        # Check for taskSpec (inline tasks are allowed)
        elif "taskSpec" not in task:
            violations.append(
                f"{pipeline_name}: task '{task_name}' has neither taskRef nor taskSpec"
            )

        # Check params for pipeline param references
        for param in task.get("params", []):
            param_value = str(param.get("value", ""))
            # Find all $(params.X) references
            for match in re.finditer(r"\$\(params\.([^)]+)\)", param_value):
                param_ref = match.group(1)
                if param_ref not in pipeline_params:
                    if (pipeline_name, "params", param_ref) not in ALLOWLIST:
                        violations.append(
                            f"{pipeline_name}: task '{task_name}' references undeclared pipeline param '{param_ref}'"
                        )

        # Check for task result references
        for param in task.get("params", []):
            param_value = str(param.get("value", ""))
            # Find all $(tasks.X.results.Y) references
            for match in re.finditer(
                r"\$\(tasks\.([^.]+)\.results\.([^)]+)\)", param_value
            ):
                ref_task = match.group(1)
                ref_result = match.group(2)
                if ref_task not in pipeline_tasks:
                    if (pipeline_name, "tasks.results", f"{ref_task}.{ref_result}") not in ALLOWLIST:
                        violations.append(
                            f"{pipeline_name}: task '{task_name}' references unknown task '{ref_task}' in result"
                        )
                else:
                    # Check if the referenced task declares this result
                    ref_task_obj = pipeline_tasks[ref_task]
                    ref_task_ref = ref_task_obj.get("taskRef", {})
                    if "name" in ref_task_ref:
                        ref_task_name = ref_task_ref["name"]
                        if ref_task_name in tasks:
                            task_results = {
                                r["name"]
                                for r in tasks[ref_task_name]
                                .get("spec", {})
                                .get("results", [])
                            }
                            if ref_result not in task_results:
                                if (pipeline_name, "tasks.results", f"{ref_task}.{ref_result}") not in ALLOWLIST:
                                    violations.append(
                                        f"{pipeline_name}: task '{task_name}' references unknown result '{ref_result}' from task '{ref_task}'"
                                    )

    # Check cell gates
    for gate_pipeline, gate_param, gate_value in cell_gates:
        if pipeline_name == gate_pipeline:
            # Every task whose name starts with cell2- must have a when with the gate
            for task_name, task in pipeline_tasks.items():
                if task_name.startswith("cell2-"):
                    # Check for when clause
                    when_clauses = task.get("when", [])
                    has_gate = False
                    for when_clause in when_clauses:
                        if (
                            when_clause.get("input") == f"$(params.{gate_param})"
                            and when_clause.get("operator") == "in"
                            and gate_value in when_clause.get("values", [])
                        ):
                            has_gate = True
                            break
                    if not has_gate:
                        if (pipeline_name, "cell-gate", task_name) not in ALLOWLIST:
                            violations.append(
                                f"{pipeline_name}: task '{task_name}' (cell2-*) missing cell gate: when input=$(params.{gate_param}) operator=in values=[{gate_value}]"
                            )

    return violations


def check_pipeline_run(pipeline_run, pipelines):
    """Check a PipelineRun for violations."""
    violations = []

    # Pipelines-as-Code run files only set metadata.generateName (templated,
    # e.g. "hcp-x-pr{{ pull_request_number }}-"); check them under that label.
    metadata = pipeline_run.get("metadata") or {}
    run_name = (
        metadata.get("name") or metadata.get("generateName") or "<unnamed PipelineRun>"
    )

    # Get pipeline reference
    pipeline_ref = (
        pipeline_run.get("spec", {}).get("pipelineRef", {}).get("name", "")
    )
    if not pipeline_ref:
        violations.append(f"{run_name}: PipelineRun has no pipelineRef.name")
        return violations

    # Find the referenced pipeline
    pipeline = None
    for p in pipelines:
        if p["metadata"]["name"] == pipeline_ref:
            pipeline = p
            break

    if not pipeline:
        violations.append(
            f"{run_name}: PipelineRun references unknown pipeline '{pipeline_ref}'"
        )
        return violations

    # Get pipeline params
    pipeline_params = {}
    for p in pipeline.get("spec", {}).get("params", []):
        pipeline_params[p["name"]] = p

    # Get run params
    run_params = {p["name"] for p in pipeline_run.get("spec", {}).get("params", [])}

    # Check that every run param is declared in the pipeline
    for param_name in run_params:
        if param_name not in pipeline_params:
            if (run_name, "param", param_name) not in ALLOWLIST:
                violations.append(
                    f"{run_name}: PipelineRun passes undeclared param '{param_name}' to pipeline '{pipeline_ref}'"
                )

    # Check that every required pipeline param is supplied
    for param_name, param_def in pipeline_params.items():
        if "default" not in param_def and param_name not in run_params:
            if (run_name, "param.required", param_name) not in ALLOWLIST:
                violations.append(
                    f"{run_name}: PipelineRun missing required param '{param_name}' for pipeline '{pipeline_ref}'"
                )

    return violations


def main():
    parser = argparse.ArgumentParser(description="Check Tekton pipeline wiring")
    parser.add_argument(
        "--cell-gate",
        action="append",
        default=[],
        help="Cell gate rule (PIPELINE:PARAM:VALUE), repeatable",
    )
    parser.add_argument("files", nargs="+", help="Pipeline and run YAML files")

    args = parser.parse_args()

    # Parse cell gates
    cell_gates = []
    for gate in args.cell_gate:
        parts = gate.split(":")
        if len(parts) != 3:
            print(
                f"Error: --cell-gate must be PIPELINE:PARAM:VALUE, got: {gate}",
                file=sys.stderr,
            )
            sys.exit(1)
        cell_gates.append(tuple(parts))

    # Load task definitions from .tekton/tasks/
    tasks_dir = find_tasks_dir()
    tasks = load_task_definitions(tasks_dir)

    # Load all YAML files (also load tasks from input files)
    pipelines = []
    pipeline_runs = []

    for file_path in args.files:
        with open(file_path, "r", encoding="utf-8") as f:
            docs = list(yaml.safe_load_all(f))
            for doc in docs:
                if not doc:
                    continue
                if doc.get("kind") == "Pipeline":
                    pipelines.append(doc)
                elif doc.get("kind") == "PipelineRun":
                    pipeline_runs.append(doc)
                elif doc.get("kind") == "Task":
                    # Also load Task definitions from input files
                    name = doc["metadata"]["name"]
                    tasks[name] = doc

    # Check pipelines
    violations = []
    for pipeline in pipelines:
        violations.extend(check_pipeline(pipeline, tasks, cell_gates))

    # Check pipeline runs
    for pipeline_run in pipeline_runs:
        violations.extend(check_pipeline_run(pipeline_run, pipelines))

    # Report violations
    if violations:
        for v in violations:
            print(v)
        sys.exit(1)


if __name__ == "__main__":
    main()
