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

    # Check for a data file for this folder and poll count
    DATA_FILE="${POLL_DATA_DIR}/${FOLDER_SAFE}_poll${CALL_COUNT}.txt"
    if [[ -f "${DATA_FILE}" ]]; then
      cat "${DATA_FILE}"
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

# elm/ has a zip from the start (polls 1-12, poll12 is for final output)
# Folder is prefix_/elm/, which becomes prefix__elm_ after replacing / with _
for i in {1..12}; do
  cat > "${POLL_DATA_DIR}/prefix__elm__poll${i}.txt" <<EOF
2026-10-26 10:00:00      12345 restricted-resources-Edge_Lifecycle_Management-1.64.0.zip
EOF
done

# edge-icell/ has nothing on polls 1-10, gets a zip on poll 11+
for i in {1..10}; do
  cat > "${POLL_DATA_DIR}/prefix__edge-icell__poll${i}.txt" <<EOF
EOF
done
for i in {11..12}; do
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

# edge-icell should be listed at least 3 times (in target folders + waiting message at poll 10 + waiting list could appear multiple times)
EDGE_ICELL_COUNT=$(echo "${TASK_OUT}" | grep -c 'edge-icell' || true)
if [[ "${EDGE_ICELL_COUNT}" -lt 2 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "edge-icell should appear at least 2 times (found ${EDGE_ICELL_COUNT})"
fi

# Should see at least one waiting message (at poll 10)
if ! echo "${TASK_OUT}" | grep -qF '⏳ still waiting for:'; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "should see waiting message at poll 10"
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

INSTRUCTIONS="Upload the bundles to the folders below"

run_with_fake_aws_poll "${CALL_COUNT_FILE}" \
  --param obcName=x \
  --param s3Prefix=prefix_ \
  --param components="elm" \
  --param instructions="${INSTRUCTIONS}" \
  --param pollSeconds=0

if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "task failed (rc ${TASK_RC})"
fi

# Instructions should appear exactly once
INSTR_COUNT=$(echo "${TASK_OUT}" | grep -c -F "${INSTRUCTIONS}" || true)
if [[ "${INSTR_COUNT}" -ne 1 ]]; then
  echo "TASK OUTPUT:"
  echo "${TASK_OUT}"
  fail "instructions should appear exactly once (found ${INSTR_COUNT})"
fi

echo "✅ PASS: prints_instructions_once"

echo ""
echo "✅ ALL TESTS PASSED"
