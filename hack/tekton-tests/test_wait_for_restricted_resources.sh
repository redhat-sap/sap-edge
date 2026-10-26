#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

TASK_YAML=../../.tekton/tasks/ossm3-wait-for-restricted-resources-task.yaml

echo "============================================"
echo "Test: wait-for-restricted-resources"
echo "============================================"

# Run the task script with a fake aws binary that simulates S3 ls polling
# Usage: run_with_fake_aws_poll CALL_COUNT_FILE [EXTRA_PARAMS...]
# Sets: AWS_LOG (log file), TASK_OUT, TASK_RC
run_with_fake_aws_poll() {
  local CALL_COUNT_FILE="$1"
  shift

  local FAKE_BIN SCRIPT RESULTS_DIR
  FAKE_BIN=$(tmp_dir)
  RESULTS_DIR=$(tmp_dir)
  AWS_LOG=$(tmp_file)

  # Fake aws: logs argv, implements s3 ls with per-folder poll simulation
  cat > "${FAKE_BIN}/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AWS_LOG}"

# If this is an "s3 ls" call, simulate poll-based output
if [[ "$1" == "s3" ]] && [[ "$2" == "ls" ]]; then
  # Extract the folder from the s3:// URL
  FOLDER=""
  for arg in "$@"; do
    if [[ "$arg" =~ ^s3://[^/]+/(.+)$ ]]; then
      FOLDER="${BASH_REMATCH[1]}"
      break
    fi
  done

  if [[ -n "${FOLDER}" ]]; then
    # Use per-folder call count
    FOLDER_SAFE="${FOLDER//\//_}"
    FOLDER_COUNT_FILE="${CALL_COUNT_FILE}.${FOLDER_SAFE}"
    CALL_COUNT=0
    if [[ -f "${FOLDER_COUNT_FILE}" ]]; then
      CALL_COUNT=$(cat "${FOLDER_COUNT_FILE}")
    fi
    CALL_COUNT=$((CALL_COUNT + 1))
    echo "${CALL_COUNT}" > "${FOLDER_COUNT_FILE}"

    # Runaway guard: a task that never stops polling gets a zip (and the test
    # fails on the marker) instead of hanging
    if [[ "${CALL_COUNT}" -gt 40 ]]; then
      echo "${FOLDER}" >> "${CALL_COUNT_FILE}.runaway"
      echo "2026-10-26 10:00:00      1 runaway.zip"
      exit 0
    fi

    # <folder>_poll<N>.fail: the listing fails (stderr text, exit 255)
    FAIL_FILE="${POLL_DATA_DIR}/${FOLDER_SAFE}_poll${CALL_COUNT}.fail"
    if [[ -f "${FAIL_FILE}" ]]; then
      cat "${FAIL_FILE}" >&2
      exit 255
    fi

    # Check for a data file for this folder and poll count; like aws s3 ls,
    # nothing under the prefix means no output and exit 1
    DATA_FILE="${POLL_DATA_DIR}/${FOLDER_SAFE}_poll${CALL_COUNT}.txt"
    if [[ -s "${DATA_FILE}" ]]; then
      cat "${DATA_FILE}"
    else
      exit 1
    fi
  fi
fi
EOF
  chmod +x "${FAKE_BIN}/aws"

  # Extract script, skipping install blocks
  SCRIPT=$(tmp_file)
  python3 -I extract_task_script.py "${TASK_YAML}" "$@" \
    --results-dir "${RESULTS_DIR}" \
    --from 'S3_ENDPOINT=' \
    > "${SCRIPT}"

  # Run with fake aws on PATH
  local OUT_FILE
  OUT_FILE=$(tmp_file)
  set +e
  export AWS_LOG CALL_COUNT_FILE POLL_DATA_DIR
  PATH="${FAKE_BIN}:${PATH}" \
    BUCKET_NAME=bkt BUCKET_HOST=h BUCKET_PORT=443 \
    bash "${SCRIPT}" > "${OUT_FILE}" 2>&1
  TASK_RC=$?
  set -e
  TASK_OUT=$(cat "${OUT_FILE}")
}

# ----------------------------------------------------------------------------
# Test: waits_until_every_folder_has_a_zip
# ----------------------------------------------------------------------------
echo ""
echo "Test: waits_until_every_folder_has_a_zip"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

# elm/ has a zip from the start (polls 1-4, poll4 is for final output)
# Folder is prefix_/elm/, which becomes prefix__elm_ after replacing / with _
for i in {1..4}; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

# edge-icell/ has nothing on polls 1-2, gets a zip on poll 3+ (as per brief)
for i in {1..2}; do
  cat > "${POLL_DATA_DIR}/prefix__edge-icell__poll${i}.txt" <<EOF
EOF
done
for i in {3..4}; do
  cat > "${POLL_DATA_DIR}/prefix__edge-icell__poll${i}.txt" <<EOF
2026-10-26 10:05:00      54321 restricted-resources-Edge_Integration_Cell-8.48.11.zip
EOF
done

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm edge-icell" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task failed (rc ${TASK_RC})"
fi

# Should succeed (rc 0)
# Should output both zip names
if ! echo "${TASK_OUT}" | grep -qF 'restricted-resources-Edge_Lifecycle_Management-1.64.0.zip'; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "output missing ELM zip name"
fi

if ! echo "${TASK_OUT}" | grep -qF 'restricted-resources-Edge_Integration_Cell-8.48.11.zip'; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "output missing EIC zip name"
fi

# edge-icell should be listed at least 3 times in the AWS call log
# (poll 1, poll 2, poll 3 when zip appears, plus final output = 4 total)
EDGE_ICELL_AWS_COUNT=$(grep -c 'prefix_/edge-icell/' "${AWS_LOG}" || true)
if [[ "${EDGE_ICELL_AWS_COUNT}" -lt 3 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  echo "AWS LOG:"
  cat "${AWS_LOG}"
  fail "edge-icell should be listed at least 3 times in AWS log (found ${EDGE_ICELL_AWS_COUNT})"
fi

echo "✅ PASS: waits_until_every_folder_has_a_zip"

# ----------------------------------------------------------------------------
# Test: ignores_markers_and_non_zips
# ----------------------------------------------------------------------------
echo ""
echo "Test: ignores_markers_and_non_zips"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

# elm/ has only marker and txt for 2 polls, then a zip on poll 3+
cat > "${POLL_DATA_DIR}/prefix__elm__poll1.txt" <<EOF
2026-10-26 10:00:00          0
2026-10-26 10:00:00        100 readme.txt
EOF
cat > "${POLL_DATA_DIR}/prefix__elm__poll2.txt" <<EOF
2026-10-26 10:00:00          0
2026-10-26 10:00:00        100 readme.txt
EOF
for i in 3 4; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00          0
2026-10-26 10:00:00        100 readme.txt
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task failed (rc ${TASK_RC})"
fi

# Check that poll count is 4 for elm folder (3 polls + 1 final output = 4 total calls)
# The per-folder count file is named ${CALL_COUNT_FILE}.prefix__elm_
ELM_COUNT_FILE="${CALL_COUNT_FILE}.prefix__elm_"
if [[ ! -f "${ELM_COUNT_FILE}" ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "elm count file not found: ${ELM_COUNT_FILE}"
fi
FINAL_POLL_COUNT=$(cat "${ELM_COUNT_FILE}")
if [[ "${FINAL_POLL_COUNT}" -ne 4 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  echo "Note: Expected 4 because: poll1 (no zip) + poll2 (no zip) + poll3 (has zip, loop breaks) + poll4 (final output)"
  fail "expected 4 calls for elm, got ${FINAL_POLL_COUNT}"
fi

echo "✅ PASS: ignores_markers_and_non_zips"

# ----------------------------------------------------------------------------
# Test: rejects_empty_components
# ----------------------------------------------------------------------------
echo ""
echo "Test: rejects_empty_components"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -eq 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task should fail with empty components (rc was 0)"
fi

# Output should contain "components"
if ! echo "${TASK_OUT}" | grep -qi 'components'; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "error message should mention 'components'"
fi

echo "✅ PASS: rejects_empty_components"

# ----------------------------------------------------------------------------
# Test: prints_instructions_once
# ----------------------------------------------------------------------------
echo ""
echo "Test: prints_instructions_once"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

# elm/ gets a zip on poll 1+ (including final output poll 2)
for i in 1 2; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

INSTRUCTION_TEXT="Upload the bundles to the folders below"

# As the param and as the env value Tekton sets from it
INSTRUCTIONS="${INSTRUCTION_TEXT}" run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param instructions="${INSTRUCTION_TEXT}" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task failed (rc ${TASK_RC})"
fi

# Instructions should appear exactly once
INSTR_COUNT=$(echo "${TASK_OUT}" | grep -c -F "${INSTRUCTION_TEXT}" || true)
if [[ "${INSTR_COUNT}" -ne 1 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "instructions should appear exactly once (found ${INSTR_COUNT})"
fi

echo "✅ PASS: prints_instructions_once"

# ----------------------------------------------------------------------------
# Test: accepts_keys_with_spaces
# ----------------------------------------------------------------------------
echo ""
echo "Test: accepts_keys_with_spaces"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

# elm/ gets a zip with a space in the name (browser repeated download naming)
for i in 1 2; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Integration_Cell-8.48.11 (1).zip
EOF
done

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task failed (rc ${TASK_RC})"
fi

# Should succeed (rc 0)
# Should output the full key with space
if ! echo "${TASK_OUT}" | grep -qF 'restricted-resources-Edge_Integration_Cell-8.48.11 (1).zip'; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "output missing zip name with space"
fi

echo "✅ PASS: accepts_keys_with_spaces"

# Number of calls the fake aws got for a folder (prefix_/<folder>/)
folder_calls() {
  cat "${CALL_COUNT_FILE}.prefix__$1_" 2>/dev/null || echo 0
}

# Fail when the task kept polling past the runaway guard
check_no_runaway() {
  if [[ -f "${CALL_COUNT_FILE}.runaway" ]]; then
    echo "TASK OUTPUT:"
    echo "${TASK_OUT}"
    fail "task kept polling after the zip appeared: $(cat "${CALL_COUNT_FILE}.runaway")"
  fi
}

LISTING_SECRET="FAKE-SECRET-IN-AWS-STDERR-0123"

# ----------------------------------------------------------------------------
# Test: listing_errors_are_retried
# ----------------------------------------------------------------------------
echo ""
echo "Test: listing_errors_are_retried"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

# elm/: the listing fails on polls 1-2 (aws exits non-zero with an error on
# stderr), then the zip is there (poll 3, plus the final listing)
for i in 1 2; do
  echo "An error occurred (InvalidAccessKeyId) when calling the ListObjectsV2 operation: ${LISTING_SECRET}" \
    > "${POLL_DATA_DIR}/prefix__elm__poll${i}.fail"
done
for i in 3 4; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task failed on a listing error (rc ${TASK_RC})"
fi
check_no_runaway
[[ "$(folder_calls elm)" -eq 4 ]] || { echo "${TASK_OUT}"; fail "expected 3 polls + the final listing for elm, got $(folder_calls elm) calls"; }
grep -qF 'restricted-resources-Edge_Lifecycle_Management-1.64.0.zip' <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "zip not listed after the listing errors"; }
# One warning for the first failure; at most one per 10 failed listings
WARNINGS=$(grep -c "⚠️  listing elm failed" <<< "${TASK_OUT}" || true)
[[ "${WARNINGS}" -eq 1 ]] || { echo "${TASK_OUT}"; fail "expected 1 listing warning, got ${WARNINGS}"; }
grep -qF "⚠️  listing elm failed (attempt 1); retrying" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "listing warning text differs"; }
# aws stderr is never printed (it could hold credentials)
! grep -qF "${LISTING_SECRET}" <<< "${TASK_OUT}" || fail "aws stderr printed in the task output"
! grep -q "syntax error" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "arithmetic error in the zip count"; }

echo "✅ PASS: listing_errors_are_retried"

# ----------------------------------------------------------------------------
# Test: failure_warnings_are_rate_limited
# ----------------------------------------------------------------------------
echo ""
echo "Test: failure_warnings_are_rate_limited"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

for i in $(seq 1 12); do
  echo "Could not connect to the endpoint URL" > "${POLL_DATA_DIR}/prefix__elm__poll${i}.fail"
done
for i in 13 14; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param pollSeconds=0

[[ "${TASK_RC}" -eq 0 ]] || { echo "${TASK_OUT}"; fail "task failed (rc ${TASK_RC})"; }
check_no_runaway
[[ "$(folder_calls elm)" -eq 14 ]] || { echo "${TASK_OUT}"; fail "expected 13 polls + the final listing, got $(folder_calls elm) calls"; }
# 12 failed listings: warnings for the 1st and the 11th only
WARNINGS=$(grep "⚠️  listing elm failed" <<< "${TASK_OUT}" || true)
[[ "${WARNINGS}" == $'⚠️  listing elm failed (attempt 1); retrying\n⚠️  listing elm failed (attempt 11); retrying' ]] \
  || { echo "${TASK_OUT}"; fail "expected warnings for attempts 1 and 11 only, got: ${WARNINGS}"; }

echo "✅ PASS: failure_warnings_are_rate_limited"

# ----------------------------------------------------------------------------
# Test: empty_folder_keeps_waiting
# ----------------------------------------------------------------------------
echo ""
echo "Test: empty_folder_keeps_waiting"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

# elm/ stays empty for 12 polls (aws s3 ls: no output, exit 1), then the zip
for i in 13 14; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task crashed on an empty folder (rc ${TASK_RC})"
fi
check_no_runaway
[[ "$(folder_calls elm)" -eq 14 ]] || { echo "${TASK_OUT}"; fail "an empty folder must keep the task waiting: expected 13 polls + the final listing, got $(folder_calls elm) calls"; }
grep -qF "⏳ still waiting for: elm" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "waiting message not printed"; }
# An empty folder is the normal waiting state, not a listing failure
! grep -q "listing elm failed" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "empty folder reported as a listing failure"; }
! grep -q "syntax error" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "arithmetic error in the zip count"; }

echo "✅ PASS: empty_folder_keeps_waiting"

# ----------------------------------------------------------------------------
# Test: final_listing_failure_is_tolerated
# ----------------------------------------------------------------------------
echo ""
echo "Test: final_listing_failure_is_tolerated"
echo "--------------------------------------------"

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"

cat > "${POLL_DATA_DIR}/prefix__elm__poll1.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
echo "An error occurred (SlowDown): ${LISTING_SECRET}" > "${POLL_DATA_DIR}/prefix__elm__poll2.fail"

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param pollSeconds=0

[[ "${TASK_RC}" -eq 0 ]] || { echo "${TASK_OUT}"; fail "a failed final listing must not fail the task (rc ${TASK_RC})"; }
[[ "$(folder_calls elm)" -eq 2 ]] || { echo "${TASK_OUT}"; fail "expected 1 poll + the final listing, got $(folder_calls elm) calls"; }
grep -qF "⚠️  listing elm failed" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "failed final listing not reported"; }
grep -qF "✅ All restricted-resources zips found" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "success not reported"; }
! grep -qF "${LISTING_SECRET}" <<< "${TASK_OUT}" || fail "aws stderr printed in the task output"

echo "✅ PASS: final_listing_failure_is_tolerated"

# ----------------------------------------------------------------------------
# Test: instructions_are_printed_verbatim
# ----------------------------------------------------------------------------
# The ROKS pipeline appends the upload plan of
# ossm3-prepare-restricted-resources-prefix to the instructions; it holds shell
# syntax ($(oc get secret ...), quotes) that must be printed, never run.
echo ""
echo "Test: instructions_are_printed_verbatim"
echo "--------------------------------------------"

python3 -I - "${TASK_YAML}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = yaml.safe_load(f)
step = task["spec"]["steps"][0]
env = {e["name"]: e for e in step.get("env", [])}
errors = []
if env.get("INSTRUCTIONS") != {"name": "INSTRUCTIONS", "value": "$(params.instructions)"}:
    errors.append(f"env INSTRUCTIONS must be $(params.instructions), got {env.get('INSTRUCTIONS')}")
if "$(params.instructions)" in step["script"]:
    errors.append("the script must read the instructions from the env, not paste $(params.instructions) into the script")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY

POLL_DATA_DIR=$(tmp_dir)
CALL_COUNT_FILE=$(tmp_file)
echo "0" > "${CALL_COUNT_FILE}"
for i in 1 2; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

MARKER_DIR=$(tmp_dir)
PLAN_LINE="  export AWS_ACCESS_KEY_ID=\$(touch ${MARKER_DIR}/ran; echo key) # jsonpath='{.data.AWS_ACCESS_KEY_ID}' \"quoted\" \`touch ${MARKER_DIR}/ran2\`"
PLAN="Upload the ELM zip to the elm/ folder below.
Upload to bucket bkt (OBC x); [current contents]:
${PLAN_LINE}"

# Passed both ways: as the param (pasted into the script by the substitution)
# and as the env value Tekton sets from it
INSTRUCTIONS="${PLAN}" run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param instructions="${PLAN}" \
  --param pollSeconds=0

[[ "${TASK_RC}" -eq 0 ]] || { echo "${TASK_OUT}"; fail "task failed with shell syntax in the instructions (rc ${TASK_RC})"; }
[[ ! -e "${MARKER_DIR}/ran" && ! -e "${MARKER_DIR}/ran2" ]] || fail "shell syntax in the instructions was executed"
grep -qxF -- "${PLAN_LINE}" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "instructions not printed verbatim"; }

echo "✅ PASS: instructions_are_printed_verbatim"

echo ""
echo "✅ ALL TESTS PASSED"
