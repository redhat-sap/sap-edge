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

# Temporary file tracking for cleanup
# Create a single temp directory to hold all temp files/dirs created by helpers
# This avoids the subshell array modification issue with VAR=$(tmp_file)
_TEST_TMP_DIR=$(mktemp -d)

# Cleanup function for EXIT trap
_cleanup_tmp_dir() {
  if [[ -n "${_TEST_TMP_DIR:-}" ]] && [[ -d "${_TEST_TMP_DIR}" ]]; then
    rm -rf "${_TEST_TMP_DIR}" 2>/dev/null || true
  fi
}

# Install EXIT trap once when lib.sh is sourced
trap _cleanup_tmp_dir EXIT

# Create a temporary file and track it for cleanup
# Usage: tmp_file
tmp_file() {
  mktemp "${_TEST_TMP_DIR}/tmp.XXXXXXXXXX"
}

# Create a temporary directory and track it for cleanup
# Usage: tmp_dir
tmp_dir() {
  mktemp -d "${_TEST_TMP_DIR}/tmp.XXXXXXXXXX"
}

# Run a task script extracted by extract_task_script.py
# Usage: [TASK_CWD=DIR] run_task TASK_YAML [extract args...]
# TASK_CWD (optional) is the directory the script runs in, standing in for the
# step's workingDir (e.g. the temp source workspace); default: current dir.
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
  (cd "${TASK_CWD:-.}" && bash "${SCRIPT}") > "${OUT_FILE}" 2>&1
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
