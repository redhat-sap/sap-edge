#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

"""
Extract a bash script from a Tekton Task YAML with parameter substitution.
"""

import sys
import argparse
import re
import yaml


def main():
    parser = argparse.ArgumentParser(
        description="Extract bash script from Tekton Task YAML"
    )
    parser.add_argument("task_yaml", help="Path to Task YAML file")
    parser.add_argument("--step", help="Step name to extract (default: first step)")
    parser.add_argument(
        "--param",
        action="append",
        default=[],
        help="Parameter assignment (KEY=VALUE), repeatable",
    )
    parser.add_argument(
        "--results-dir", default="/tmp/results", help="Directory for result files"
    )
    parser.add_argument(
        "--workspace-dir",
        action="append",
        default=[],
        help="Workspace directory (NAME=PATH), repeatable",
    )
    parser.add_argument("--namespace", default="default", help="TaskRun namespace")
    parser.add_argument(
        "--drop",
        action="append",
        nargs=2,
        metavar=("START", "END"),
        default=[],
        help="Drop lines from first containing START to next containing END (inclusive), repeatable",
    )
    parser.add_argument(
        "--from", dest="from_literal", help="Keep only from this literal (inclusive)"
    )
    parser.add_argument(
        "--to", dest="to_literal", help="Keep only to this literal (exclusive)"
    )

    args = parser.parse_args()

    # Parse parameters
    params = {}
    for p in args.param:
        if "=" not in p:
            print(f"Error: --param must be KEY=VALUE, got: {p}", file=sys.stderr)
            sys.exit(1)
        k, v = p.split("=", 1)
        params[k] = v

    # Parse workspace directories
    workspace_dirs = {}
    for w in args.workspace_dir:
        if "=" not in w:
            print(
                f"Error: --workspace-dir must be NAME=PATH, got: {w}", file=sys.stderr
            )
            sys.exit(1)
        k, v = w.split("=", 1)
        workspace_dirs[k] = v

    # Load Task YAML
    with open(args.task_yaml, "r", encoding="utf-8") as f:
        docs = list(yaml.safe_load_all(f))

    # Find the Task document
    task = None
    for doc in docs:
        if doc and doc.get("kind") == "Task":
            task = doc
            break

    if not task:
        print(f"Error: No Task found in {args.task_yaml}", file=sys.stderr)
        sys.exit(1)

    # Get task defaults for parameters
    task_params = {}
    for param in task.get("spec", {}).get("params", []):
        name = param["name"]
        if "default" in param:
            task_params[name] = param["default"]
        else:
            task_params[name] = None  # Required param

    # Merge with provided params (provided params override defaults)
    for name in task_params:
        if name not in params:
            if task_params[name] is None:
                print(
                    f"Error: Required parameter '{name}' not provided", file=sys.stderr
                )
                sys.exit(1)
            params[name] = task_params[name]

    # Get the script
    steps = task.get("spec", {}).get("steps", [])
    if not steps:
        print(f"Error: No steps found in Task", file=sys.stderr)
        sys.exit(1)

    if args.step:
        step = None
        for s in steps:
            if s.get("name") == args.step:
                step = s
                break
        if not step:
            print(f"Error: Step '{args.step}' not found", file=sys.stderr)
            sys.exit(1)
    else:
        step = steps[0]

    script = step.get("script", "")
    if not script:
        print(f"Error: Step has no script", file=sys.stderr)
        sys.exit(1)

    # Substitute parameters: $(params.NAME)
    def sub_param(match):
        param_name = match.group(1)
        if param_name not in params:
            print(
                f"Error: Parameter '{param_name}' referenced but not defined",
                file=sys.stderr,
            )
            sys.exit(1)
        return params[param_name]

    script = re.sub(r"\$\(params\.([^)]+)\)", sub_param, script)

    # Substitute results: $(results.NAME.path)
    script = re.sub(
        r"\$\(results\.([^)]+)\.path\)", rf"{args.results_dir}/\1", script
    )

    # Substitute workspaces: $(workspaces.NAME.path)
    def sub_workspace(match):
        ws_name = match.group(1)
        if ws_name in workspace_dirs:
            return workspace_dirs[ws_name]
        return f"/workspace/{ws_name}"

    script = re.sub(r"\$\(workspaces\.([^)]+)\.path\)", sub_workspace, script)

    # Substitute context: $(context.taskRun.namespace)
    script = re.sub(r"\$\(context\.taskRun\.namespace\)", args.namespace, script)

    # Apply --from/--to filtering
    lines = script.split("\n")

    # Find first install/header boundary
    install_line = -1
    for i, line in enumerate(lines):
        if "# Install" in line or '# echo "📦 Installing' in line or 'echo "📦 Installing' in line:
            install_line = i
            break

    if args.from_literal or args.to_literal:
        # Always keep everything before the first install line (variable header)
        header_lines = []
        if install_line >= 0:
            header_lines = lines[:install_line]

        # Find from/to boundaries
        from_idx = 0
        to_idx = len(lines)

        if args.from_literal:
            for i, line in enumerate(lines):
                if args.from_literal in line:
                    from_idx = i
                    break
            else:
                print(
                    f"Error: --from literal '{args.from_literal}' not found",
                    file=sys.stderr,
                )
                sys.exit(1)

        if args.to_literal:
            for i, line in enumerate(lines):
                if args.to_literal in line:
                    to_idx = i
                    break
            else:
                print(
                    f"Error: --to literal '{args.to_literal}' not found",
                    file=sys.stderr,
                )
                sys.exit(1)

        # Combine header with selected range
        if install_line >= 0 and from_idx > install_line:
            lines = header_lines + lines[from_idx:to_idx]
        else:
            lines = lines[from_idx:to_idx]

    # Apply --drop ranges
    for start_lit, end_lit in args.drop:
        new_lines = []
        i = 0
        while i < len(lines):
            if start_lit in lines[i]:
                # Find the end line
                j = i + 1
                while j < len(lines):
                    if end_lit in lines[j]:
                        i = j + 1  # Skip past the end line
                        break
                    j += 1
                else:
                    # End not found, drop to end of file
                    break
            else:
                new_lines.append(lines[i])
                i += 1
        lines = new_lines

    # Output the processed script
    print("\n".join(lines))


if __name__ == "__main__":
    main()
