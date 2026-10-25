# Tekton Test Harness

Local test harness for Tekton task embedded scripts and pipeline wiring validation.

## Overview

This harness provides:

1. **Script extraction** (`extract_task_script.py`) - Extracts bash scripts from Tekton Task YAML files with parameter substitution
2. **Pipeline validation** (`check_pipeline.py`) - Validates pipeline wiring, references, and constraints
3. **Test helpers** (`lib.sh`) - Bash library for testing extracted scripts
4. **Fake binaries** (`fake-bin/oc`, `fake-bin/kubectl`) - Mock `oc`/`kubectl` for testing without a cluster

## Usage

Run all tests and validations:

```bash
bash hack/tekton-tests/run.sh
```

Run individual test files:

```bash
bash hack/tekton-tests/test_harness.sh
bash hack/tekton-tests/test_download_and_apply_rbac.sh
```

## Tools

### extract_task_script.py

Extract and preprocess bash scripts from Tekton Tasks:

```bash
python3 -I extract_task_script.py TASK.yaml \
  [--step NAME] \
  [--param KEY=VALUE]... \
  [--results-dir DIR] \
  [--workspace-dir NAME=PATH]... \
  [--namespace NS] \
  [--drop 'START' 'END']... \
  [--from 'LITERAL'] \
  [--to 'LITERAL']
```

- Substitutes `$(params.X)`, `$(results.Y.path)`, `$(workspaces.Z.path)`, `$(context.taskRun.namespace)`
- `--drop`: Remove inclusive range from first line containing START to next containing END
- `--from`/`--to`: Extract range (always keeps variable header before install blocks)

### check_pipeline.py

Validate pipeline wiring:

```bash
python3 -I check_pipeline.py \
  [--cell-gate PIPELINE:PARAM:VALUE]... \
  FILES...
```

`run.sh` checks all pipelines in `.tekton/pipelines/` and all PipelineRuns in both `.tekton/` and `.tekton-examples/`.

Checks:

- `runAfter` targets exist
- Pipeline params are declared
- Task result references are valid
- Task params are declared and required params are passed
- Workspaces are bound
- ApprovalTasks have no `when`
- Cell gates: `cell2-*` tasks have required `when` clauses

### lib.sh

Test helper functions:

```bash
source lib.sh

run_task TASK.yaml [extract args...]  # Extract and run, stores output/rc
TASK_CWD=DIR run_task TASK.yaml ...   # Same, run in DIR (stands in for the step's workingDir)
assert_called PATTERN                  # Check fake oc was called
assert_not_called PATTERN              # Check fake oc was NOT called
assert_file_contains FILE PATTERN      # Check file content
assert_rc N                            # Check task exit code
fail MSG                               # Fail test with message
tmp_file [template]                    # Create temp file, auto-cleanup on EXIT
tmp_dir [template]                     # Create temp dir, auto-cleanup on EXIT
```

**Temporary file management:**

- `tmp_file` and `tmp_dir` create temporary files/directories and track them for automatic cleanup
- A single EXIT trap installed by lib.sh removes all tracked paths when the test exits
- Use these instead of `mktemp` + per-case `trap` to avoid trap overwriting bugs
- Safe under `set -u` (bash 3.2 compatible)

### fake-bin/oc

Mock `oc`/`kubectl` for testing:

```bash
export FAKE_OC_LOG=/tmp/calls.log          # Log all calls
export FAKE_OC_RULES=/tmp/rules.txt        # Response rules
export FAKE_OC_STDIN_DIR=/tmp/applied      # Save applied YAML

fake-bin/oc get pods
```

Rules file format (tab-separated):

```
GLOB<TAB>EXIT_CODE<TAB>STDOUT
```

Example:

```
get pods*	0	pod1\npod2
delete pod foo	1	Error: not found
```

## Testing Patterns

### Testing a task script section

```bash
#!/usr/bin/env bash
source hack/tekton-tests/lib.sh

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)

cat > "${FAKE_OC_RULES}" <<'EOF'
get secret *	0	{"data":{"key":"dmFsdWU="}}
EOF

export FAKE_OC_LOG FAKE_OC_RULES

run_task .tekton/tasks/my-task.yaml \
  --param clusterName=test \
  --drop '# Install' 'aws --version'

assert_rc 0
assert_called "get secret"
```

## Fixtures

- `fixtures/broken-pipeline.yaml` - Pipeline with seeded violations for checker testing
- `fixtures/broken-run.yaml` - PipelineRun with violations

## Implementation Notes

- Runs on macOS with bash 3.2 (guards `${array[@]}` under `set -u`)
- Uses `sort -V` for version sorting
- No `grep -P` (uses `sed`/`grep -E` instead)
- All scripts pass `shellcheck -x`
- All files have SPDX headers
