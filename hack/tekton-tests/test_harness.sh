#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "============================================"
echo "Test: check_pipeline.py validation rules"
echo "============================================"

# Test that the checker detects all seeded violations
if OUTPUT=$(python3 -I check_pipeline.py --cell-gate broken:cellCount:2 fixtures/broken-pipeline.yaml fixtures/broken-run.yaml 2>&1); then
  echo "❌ FAIL: checker should have exited 1 but succeeded"
  exit 1
fi

# Check for expected violations
EXPECTED_VIOLATIONS=(
  "no-such-task"
  "param 'missing'"
  "result 'nope'"
  "bogus"
  "ApprovalTask.*when"
  "cell2-x"
  "unknownParam"
  "missing-required-workspace.*required-ws"
  "broken-pac-pr.*unknown pipeline 'no-such-pipeline'"
)

for PATTERN in "${EXPECTED_VIOLATIONS[@]}"; do
  if ! grep -qE "${PATTERN}" <<< "${OUTPUT}"; then
    echo "❌ FAIL: checker did not report violation matching: ${PATTERN}"
    echo "Checker output:"
    echo "${OUTPUT}"
    exit 1
  fi
done

echo "✅ PASS: checker detected all seeded violations"

# Verify that optional-workspace-ok task does NOT trigger a violation
if grep -qE "optional-workspace-ok" <<< "${OUTPUT}"; then
  echo "❌ FAIL: checker incorrectly flagged optional workspace as missing"
  echo "Checker output:"
  echo "${OUTPUT}"
  exit 1
fi

echo "✅ PASS: checker correctly allows unbound optional workspaces"

echo ""
echo "============================================"
echo "Test: extract_task_script.py substitutions"
echo "============================================"

# Test that the extractor substitutes params correctly
EXTRACT_OUTPUT=$(python3 -I extract_task_script.py ../../.tekton/tasks/ossm3-prepare-restricted-resources-prefix-task.yaml --param components='elm edge-icell-1')

if ! grep -qF 'COMPONENTS="elm edge-icell-1"' <<< "${EXTRACT_OUTPUT}"; then
  echo "❌ FAIL: extractor did not substitute params.components correctly"
  echo "Extractor output:"
  echo "${EXTRACT_OUTPUT}"
  exit 1
fi

# shellcheck disable=SC2016
if grep -qF '$(params.' <<< "${EXTRACT_OUTPUT}"; then
  echo "❌ FAIL: extractor left unsubstituted \$(params. in output"
  echo "Extractor output:"
  echo "${EXTRACT_OUTPUT}"
  exit 1
fi

echo "✅ PASS: extractor substituted parameters correctly"

echo ""
echo "============================================"
echo "Test: fake oc with rules"
echo "============================================"

# Test fake oc with rules
FAKE_OC_LOG=$(mktemp)
FAKE_OC_RULES=$(mktemp)
trap 'rm -f "${FAKE_OC_LOG}" "${FAKE_OC_RULES}"' EXIT

# Write rules with embedded newline in STDOUT field
printf 'get ns*\t0\ta\\nb\n' > "${FAKE_OC_RULES}"

export FAKE_OC_LOG FAKE_OC_RULES
OUTPUT=$(fake-bin/oc get ns -l x)

if [[ ! -f "${FAKE_OC_LOG}" ]]; then
  echo "❌ FAIL: fake oc did not create log file"
  exit 1
fi

if ! grep -qF "get ns -l x" "${FAKE_OC_LOG}"; then
  echo "❌ FAIL: fake oc did not log the call"
  cat "${FAKE_OC_LOG}"
  exit 1
fi

LINES=$(echo -n "${OUTPUT}" | grep -c '^')
if [[ "${LINES}" -ne 2 ]]; then
  echo "❌ FAIL: fake oc should have printed 2 lines, got ${LINES}"
  echo "${OUTPUT}"
  exit 1
fi

echo "✅ PASS: fake oc logged call and followed rules correctly"

# Stderr rules: printed to stderr, stdout stays separate
FAKE_OC_STDERR_RULES=$(mktemp)
trap 'rm -f "${FAKE_OC_LOG}" "${FAKE_OC_RULES}" "${FAKE_OC_STDERR_RULES}"' EXIT
export FAKE_OC_STDERR_RULES
printf 'get ns edgelm\t0\t{}\n' > "${FAKE_OC_RULES}"
printf 'get ns edgelm\tWarning: noisy\n' > "${FAKE_OC_STDERR_RULES}"
STDOUT_ONLY=$(fake-bin/oc get ns edgelm 2>/dev/null)
STDERR_ONLY=$(fake-bin/oc get ns edgelm 2>&1 >/dev/null)
if [[ "${STDOUT_ONLY}" != "{}" || "${STDERR_ONLY}" != "Warning: noisy" ]]; then
  echo "❌ FAIL: fake oc should print the rule to stdout and the stderr rule to stderr, got '${STDOUT_ONLY}' / '${STDERR_ONLY}'"
  exit 1
fi
# Without a matching stderr rule nothing goes to stderr
if [[ -n "$(fake-bin/oc get ns other 2>&1 >/dev/null)" ]]; then
  echo "❌ FAIL: fake oc printed to stderr without a matching stderr rule"
  exit 1
fi

echo "✅ PASS: fake oc prints stderr rules to stderr"

echo ""
echo "============================================"
echo "✅ ALL TESTS PASSED"
echo "============================================"
