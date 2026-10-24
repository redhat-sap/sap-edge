#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

# Test library for Tekton task scripts

# Global variables for task output (exported for use by tests)
# shellcheck disable=SC2034
TASK_OUT=""
# shellcheck disable=SC2034
TASK_RC=""

# Run a task script extracted by extract_task_script.py
# Usage: run_task TASK_YAML [extract args...]
run_task() {
  local TASK_YAML="$1"
  shift

  # Create temp files
  local SCRIPT
  SCRIPT=$(mktemp)
  local OUT_FILE
  OUT_FILE=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${SCRIPT}' '${OUT_FILE}'" RETURN

  # Extract the script
  python3 -I extract_task_script.py "${TASK_YAML}" "$@" > "${SCRIPT}"

  # Run with fake oc in PATH
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export PATH="${SCRIPT_DIR}/fake-bin:${PATH}"

  # Run the script and capture output and exit code
  set +e
  bash "${SCRIPT}" > "${OUT_FILE}" 2>&1
  TASK_RC=$?
  set -e

  TASK_OUT=$(cat "${OUT_FILE}")
}

# Assert that fake oc was called with a pattern
# Usage: assert_called PATTERN
assert_called() {
  local PATTERN="$1"
  if [[ -z "${FAKE_OC_LOG:-}" ]] || [[ ! -f "${FAKE_OC_LOG}" ]]; then
    fail "assert_called: FAKE_OC_LOG not set or file doesn't exist"
  fi
  if ! grep -qE "${PATTERN}" "${FAKE_OC_LOG}"; then
    fail "assert_called: fake oc was not called with pattern '${PATTERN}'"
  fi
}

# Assert that fake oc was NOT called with a pattern
# Usage: assert_not_called PATTERN
assert_not_called() {
  local PATTERN="$1"
  if [[ -z "${FAKE_OC_LOG:-}" ]] || [[ ! -f "${FAKE_OC_LOG}" ]]; then
    fail "assert_not_called: FAKE_OC_LOG not set or file doesn't exist"
  fi
  if grep -qE "${PATTERN}" "${FAKE_OC_LOG}"; then
    fail "assert_not_called: fake oc was called with pattern '${PATTERN}'"
  fi
}

# Assert that a file contains a pattern
# Usage: assert_file_contains FILE PATTERN
assert_file_contains() {
  local FILE="$1"
  local PATTERN="$2"
  if [[ ! -f "${FILE}" ]]; then
    fail "assert_file_contains: file '${FILE}' not found"
  fi
  if ! grep -qE "${PATTERN}" "${FILE}"; then
    fail "assert_file_contains: file '${FILE}' doesn't contain pattern '${PATTERN}'"
  fi
}

# Assert that the task exited with a specific code
# Usage: assert_rc N
assert_rc() {
  local EXPECTED="$1"
  if [[ "${TASK_RC}" -ne "${EXPECTED}" ]]; then
    fail "assert_rc: expected exit code ${EXPECTED}, got ${TASK_RC}"
  fi
}

# Fail with a message
# Usage: fail MSG
fail() {
  echo "❌ FAIL: $1" >&2
  exit 1
}
