#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

TASK_YAML=../../.tekton/tasks/ossm3-prepare-restricted-resources-prefix-task.yaml

echo "============================================"
echo "Test: prepare-prefix archive feature"
echo "============================================"

# Run the task script with a fake aws binary that logs arguments
# Usage: run_with_fake_aws [EXTRA_PARAMS...]
# Sets: AWS_LOG (log file), TASK_OUT, TASK_RC
run_with_fake_aws() {
  local FAKE_BIN SCRIPT RESULTS_DIR
  FAKE_BIN=$(tmp_dir)
  RESULTS_DIR=$(tmp_dir)
  AWS_LOG=$(tmp_file)

  # Fake aws: logs argv and prints nothing
  cat > "${FAKE_BIN}/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AWS_LOG}"
EOF
  chmod +x "${FAKE_BIN}/aws"

  # Fake oc: logs argv (needed for s3 route lookup)
  cat > "${FAKE_BIN}/oc" <<'EOF'
#!/usr/bin/env bash
# Return empty for route lookup (will use fallback)
exit 0
EOF
  chmod +x "${FAKE_BIN}/oc"

  # Extract script, skipping install blocks
  SCRIPT=$(tmp_file)
  python3 -I extract_task_script.py "${TASK_YAML}" "$@" \
    --results-dir "${RESULTS_DIR}" \
    --from 'S3_ENDPOINT=' \
    > "${SCRIPT}"

  # Run with fake aws on PATH
  set +e
  PATH="${FAKE_BIN}:${PATH}" \
    BUCKET_NAME=bkt BUCKET_HOST=h BUCKET_PORT=443 \
    AWS_LOG="${AWS_LOG}" \
    bash "${SCRIPT}" > /dev/null 2>&1
  TASK_RC=$?
  set -e
}

# ----------------------------------------------------------------------------
# Test: archive_moves_only_zips
# ----------------------------------------------------------------------------
echo ""
echo "Test: archive_moves_only_zips"
echo "--------------------------------------------"

run_with_fake_aws \
  --param obcName=x \
  --param s3Prefix=restricted-resources/c1/ \
  --param components="elm edge-icell" \
  --param archiveExisting=true

if [[ "${TASK_RC}" -ne 0 ]]; then
  fail "task failed (rc ${TASK_RC})"
fi

# Check that mv was called for both components with correct flags
if ! grep -qF 's3 mv s3://bkt/restricted-resources/c1/elm/ s3://bkt/restricted-resources/c1/archive/' "${AWS_LOG}"; then
  cat "${AWS_LOG}"
  fail "aws s3 mv for elm/ not found in log"
fi

if ! grep -qF 's3 mv s3://bkt/restricted-resources/c1/edge-icell/ s3://bkt/restricted-resources/c1/archive/' "${AWS_LOG}"; then
  cat "${AWS_LOG}"
  fail "aws s3 mv for edge-icell/ not found in log"
fi

# Check that mv includes the correct filters
if ! grep -qF -- '--exclude * --include *.zip' "${AWS_LOG}"; then
  cat "${AWS_LOG}"
  fail "mv command missing --exclude/--include filters"
fi

# Check that mv calls come before put-object calls
MV_LINE=$(grep -n 's3 mv' "${AWS_LOG}" | head -1 | cut -d: -f1)
PUT_LINE=$(grep -n 'put-object' "${AWS_LOG}" | head -1 | cut -d: -f1)
if [[ "${MV_LINE}" -ge "${PUT_LINE}" ]]; then
  cat "${AWS_LOG}"
  fail "mv calls must come before put-object calls"
fi

echo "✅ PASS: archive_moves_only_zips"

# ----------------------------------------------------------------------------
# Test: archive_off_by_default
# ----------------------------------------------------------------------------
echo ""
echo "Test: archive_off_by_default"
echo "--------------------------------------------"

run_with_fake_aws \
  --param obcName=x \
  --param s3Prefix=restricted-resources/c1/ \
  --param components="elm edge-icell"

if [[ "${TASK_RC}" -ne 0 ]]; then
  fail "task failed (rc ${TASK_RC})"
fi

# Check that mv was NOT called
if grep -qF 's3 mv' "${AWS_LOG}"; then
  cat "${AWS_LOG}"
  fail "s3 mv should not be called when archiveExisting is not set"
fi

echo "✅ PASS: archive_off_by_default"

# ----------------------------------------------------------------------------
# Test: archive_skipped_for_flat_prefix
# ----------------------------------------------------------------------------
echo ""
echo "Test: archive_skipped_for_flat_prefix"
echo "--------------------------------------------"

run_with_fake_aws \
  --param obcName=x \
  --param s3Prefix=restricted-resources/c1/ \
  --param components="" \
  --param archiveExisting=true

if [[ "${TASK_RC}" -ne 0 ]]; then
  fail "task failed (rc ${TASK_RC})"
fi

# Check that mv was NOT called (flat prefix, no components)
if grep -qF 's3 mv' "${AWS_LOG}"; then
  cat "${AWS_LOG}"
  fail "s3 mv should not be called for flat prefix (empty components)"
fi

echo "✅ PASS: archive_skipped_for_flat_prefix"

echo ""
echo "✅ ALL TESTS PASSED"
