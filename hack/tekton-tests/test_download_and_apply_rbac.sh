#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

TASK_YAML=../../.tekton/tasks/ossm3-download-and-apply-rbac-task.yaml

echo "============================================"
echo "Test: ossm3-download-and-apply-rbac"
echo "============================================"

# Make a bundle zip whose only file, marker.txt, holds MARKER.
# Usage: make_zip DIR ZIP_NAME MARKER
make_zip() {
  local DIR="$1" ZIP_NAME="$2" MARKER="$3" WORK
  WORK=$(tmp_dir)
  mkdir -p "${DIR}"
  printf '%s\n' "${MARKER}" > "${WORK}/marker.txt"
  (cd "${WORK}" && zip -q "${ZIP_NAME}" marker.txt)
  mv "${WORK}/${ZIP_NAME}" "${DIR}/${ZIP_NAME}"
}

# Print the extracted bundle directory names (sorted).
extracted_dirs() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# Fail unless the extracted directory names equal the expected ones.
# Usage: assert_extracted RBAC_DIR NAME...
assert_extracted() {
  local DIR="$1" ACTUAL EXPECTED
  shift
  ACTUAL=$(extracted_dirs "${DIR}")
  EXPECTED=$(printf '%s\n' "$@" | sort)
  if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
    echo "Expected:"
    echo "${EXPECTED}"
    echo "Actual:"
    echo "${ACTUAL}"
    fail "extracted bundle directories differ"
  fi
}

# Fail unless FILE's content is exactly EXPECTED.
assert_marker() {
  local FILE="$1" EXPECTED="$2"
  [[ -f "${FILE}" ]] || fail "${FILE} not extracted"
  if [[ "$(cat "${FILE}")" != "${EXPECTED}" ]]; then
    fail "${FILE}: expected '${EXPECTED}', got '$(cat "${FILE}")'"
  fi
}

# ----------------------------------------------------------------------------
# Step 2: per-component discovery, ordering, latest version
# ----------------------------------------------------------------------------
echo ""
echo "Test: step2_order_and_latest_version"
echo "--------------------------------------------"

TEST_DOWNLOAD_DIR=$(tmp_dir)
TEST_RBAC_DIR=$(tmp_dir)

# elm-1 holds three versions with distinct content; 1.9.0 sorts last
# lexically, so only a version sort picks 1.62.0-rc.1.
make_zip "${TEST_DOWNLOAD_DIR}/elm-1" restricted-resources-Edge_Lifecycle_Management-1.9.0.zip "elm-1 1.9.0"
make_zip "${TEST_DOWNLOAD_DIR}/elm-1" restricted-resources-Edge_Lifecycle_Management-1.58.0.zip "elm-1 1.58.0"
make_zip "${TEST_DOWNLOAD_DIR}/elm-1" restricted-resources-Edge_Lifecycle_Management-1.62.0-rc.1.zip "elm-1 1.62.0-rc.1"
make_zip "${TEST_DOWNLOAD_DIR}/elm-2" restricted-resources-Edge_Lifecycle_Management-1.60.0.zip "elm-2 1.60.0"
# edge-icell-10 checks the version sort of component names (2 before 10)
make_zip "${TEST_DOWNLOAD_DIR}/edge-icell-1" restricted-resources-Edge_Integration_Cell-2.0.0.zip "edge-icell-1 2.0.0"
make_zip "${TEST_DOWNLOAD_DIR}/edge-icell-2" restricted-resources-Edge_Integration_Cell-2.0.0.zip "edge-icell-2 2.0.0"
make_zip "${TEST_DOWNLOAD_DIR}/edge-icell-10" restricted-resources-Edge_Integration_Cell-2.0.0.zip "edge-icell-10 2.0.0"

SCRIPT=$(tmp_file)
# Step 2 reads DOWNLOAD_DIR from Step 1: inject it after the shebang.
python3 -I extract_task_script.py "${TASK_YAML}" \
  --param hostedClusterName=test-cluster \
  --param requiredComponents='elm-1 elm-2 edge-icell-1 edge-icell-2 edge-icell-10' \
  --from '# Step 2:' \
  --to '# Step 3:' \
  | sed -e "1a\\
DOWNLOAD_DIR=\"${TEST_DOWNLOAD_DIR}\"" \
        -e "s|RBAC_DIR=\"/tmp/rbac-resources\"|RBAC_DIR=\"${TEST_RBAC_DIR}\"|" \
  > "${SCRIPT}"
grep -qF "RBAC_DIR=\"${TEST_RBAC_DIR}\"" "${SCRIPT}" || fail "RBAC_DIR substitution failed"

BUCKET_NAME="test-bucket" S3_PREFIX="test-prefix/" bash "${SCRIPT}"

EXTRACTED_DIRS=$(find "${TEST_RBAC_DIR}" -mindepth 1 -maxdepth 1 -type d | sort -V)
EXPECTED_ORDER=(
  "00_elm-1_Edge_Lifecycle_Management"
  "00_elm-2_Edge_Lifecycle_Management"
  "20_edge-icell-1_Edge_Integration_Cell"
  "20_edge-icell-2_Edge_Integration_Cell"
  "20_edge-icell-10_Edge_Integration_Cell"
)
ACTUAL_ORDER=()
while IFS= read -r DIR; do
  ACTUAL_ORDER+=("$(basename "${DIR}")")
done <<< "${EXTRACTED_DIRS}"
if [[ "${ACTUAL_ORDER[*]}" != "${EXPECTED_ORDER[*]}" ]]; then
  echo "Expected: ${EXPECTED_ORDER[*]}"
  echo "Actual:   ${ACTUAL_ORDER[*]}"
  fail "bundle directories not in apply order"
fi
echo "✅ PASS: directories in correct order"

# Only the newest elm-1 bundle may be extracted.
assert_marker "${TEST_RBAC_DIR}/00_elm-1_Edge_Lifecycle_Management/marker.txt" "elm-1 1.62.0-rc.1"
assert_marker "${TEST_RBAC_DIR}/20_edge-icell-10_Edge_Integration_Cell/marker.txt" "edge-icell-10 2.0.0"
echo "✅ PASS: elm-1 extracted latest version (1.62.0-rc.1)"

# ----------------------------------------------------------------------------
# Step 1: download filters (one bucket shared by flat and per-PR prefixes)
# ----------------------------------------------------------------------------
# Fake bucket: a flat single-EIC set directly under restricted-resources/ plus
# the per-PR folders of a topology A run (pr123) and a topology B run
# (pr124-multi-stack).
FAKE_S3_ROOT=$(tmp_dir)
RR="${FAKE_S3_ROOT}/test-bucket/restricted-resources"
make_zip "${RR}" restricted-resources-Edge_Lifecycle_Management-1.60.0.zip "root elm"
make_zip "${RR}" restricted-resources-Edge_Integration_Cell-8.40.0.zip "root eic"
make_zip "${RR}/pr123/elm" restricted-resources-Edge_Lifecycle_Management-1.64.0.zip "pr123 elm"
make_zip "${RR}/pr123/edge-icell-1" restricted-resources-Edge_Integration_Cell-8.48.0.zip "pr123 edge-icell-1"
make_zip "${RR}/pr123/edge-icell-2" restricted-resources-Edge_Integration_Cell-8.48.0.zip "pr123 edge-icell-2"
make_zip "${RR}/pr123/edge-icell-3" restricted-resources-Edge_Integration_Cell-8.48.0.zip "pr123 edge-icell-3 (not listed)"
make_zip "${RR}/pr124-multi-stack/elm-1" restricted-resources-Edge_Lifecycle_Management-1.64.0.zip "pr124 elm-1"
make_zip "${RR}/pr124-multi-stack/edge-icell-1" restricted-resources-Edge_Integration_Cell-8.48.0.zip "pr124 edge-icell-1"

# Stub aws: logs its exact argv as [arg][arg]…, then copies the objects that
# `aws s3 cp --recursive` would copy with the given --exclude/--include filters
# (matched against the key relative to the source prefix, `*` spans "/", the
# last matching filter wins, default include).
STUB_BIN=$(tmp_dir)
cat > "${STUB_BIN}/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '[%s]' "$@" >> "${FAKE_AWS_LOG}"
printf '\n' >> "${FAKE_AWS_LOG}"
[[ "${1:-}" == "s3" && "${2:-}" == "cp" ]] || exit 0
SRC="$3"
DST="${4%/}"
shift 4
FILTERS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude|--include) FILTERS+=("$1" "$2"); shift 2 ;;
    --endpoint-url) shift 2 ;;
    *) shift ;;
  esac
done
ROOT="${FAKE_S3_ROOT}/${SRC#s3://}"
ROOT="${ROOT%/}"
[[ -d "${ROOT}" ]] || exit 0
while IFS= read -r FILE; do
  REL="${FILE#"${ROOT}"/}"
  KEEP=1
  I=0
  while [[ ${I} -lt ${#FILTERS[@]} ]]; do
    # shellcheck disable=SC2053
    if [[ "${REL}" == ${FILTERS[$((I + 1))]} ]]; then
      if [[ "${FILTERS[${I}]}" == "--include" ]]; then KEEP=1; else KEEP=0; fi
    fi
    I=$((I + 2))
  done
  if [[ ${KEEP} -eq 1 ]]; then
    mkdir -p "$(dirname "${DST}/${REL}")"
    cp "${FILE}" "${DST}/${REL}"
  fi
done < <(find "${ROOT}" -type f)
EOF
chmod +x "${STUB_BIN}/aws"

# Run Steps 1-2 of the task against the fake bucket.
# Usage: run_download S3_PREFIX REQUIRED_COMPONENTS
# Sets DL_DIR, RBAC_OUT, FAKE_AWS_LOG, STEP_OUT, STEP_RC.
run_download() {
  local SCRIPT
  DL_DIR=$(tmp_dir)
  RBAC_OUT=$(tmp_dir)
  FAKE_AWS_LOG=$(tmp_file)
  SCRIPT=$(tmp_file)
  python3 -I extract_task_script.py "${TASK_YAML}" \
    --param hostedClusterName=test-cluster \
    --param s3Prefix="$1" \
    --param requiredComponents="$2" \
    --from '# Step 1:' \
    --to '# Step 3:' \
    | sed -e "s|DOWNLOAD_DIR=\"/tmp/restricted-resources\"|DOWNLOAD_DIR=\"${DL_DIR}\"|" \
          -e "s|RBAC_DIR=\"/tmp/rbac-resources\"|RBAC_DIR=\"${RBAC_OUT}\"|" \
    > "${SCRIPT}"
  grep -qF "DOWNLOAD_DIR=\"${DL_DIR}\"" "${SCRIPT}" || fail "DOWNLOAD_DIR substitution failed"
  grep -qF "RBAC_DIR=\"${RBAC_OUT}\"" "${SCRIPT}" || fail "RBAC_DIR substitution failed"
  set +e
  STEP_OUT=$(PATH="${STUB_BIN}:${PATH}" FAKE_AWS_LOG="${FAKE_AWS_LOG}" FAKE_S3_ROOT="${FAKE_S3_ROOT}" \
    BUCKET_NAME=test-bucket BUCKET_HOST=s3.example.test BUCKET_PORT=443 \
    bash "${SCRIPT}" 2>&1)
  STEP_RC=$?
  set -e
}

# Fail unless the stub aws was called exactly once with EXPECTED argv.
assert_aws_args() {
  local EXPECTED="$1" ACTUAL
  ACTUAL=$(cat "${FAKE_AWS_LOG}")
  if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
    echo "Expected: ${EXPECTED}"
    echo "Actual:   ${ACTUAL}"
    fail "unexpected aws s3 cp arguments"
  fi
}

echo ""
echo "Test: flat_prefix_downloads_top_level_only"
echo "--------------------------------------------"

run_download "restricted-resources/" ""
if [[ "${STEP_RC}" -ne 0 ]]; then
  echo "${STEP_OUT}"
  fail "flat prefix run failed (rc ${STEP_RC})"
fi
assert_aws_args "[s3][cp][s3://test-bucket/restricted-resources/][${DL_DIR}/][--endpoint-url][https://s3.example.test:443][--no-verify-ssl][--recursive][--exclude][*/*]"
if [[ -n "$(find "${DL_DIR}" -mindepth 1 -type d)" ]]; then
  find "${DL_DIR}"
  fail "flat prefix must not download any subfolder"
fi
assert_extracted "${RBAC_OUT}" \
  "00_root_Edge_Lifecycle_Management" \
  "20_root_Edge_Integration_Cell"
assert_marker "${RBAC_OUT}/00_root_Edge_Lifecycle_Management/marker.txt" "root elm"
assert_marker "${RBAC_OUT}/20_root_Edge_Integration_Cell/marker.txt" "root eic"
echo "✅ PASS: flat_prefix_downloads_top_level_only"

echo ""
echo "Test: components_download_only_listed_folders"
echo "--------------------------------------------"

# No trailing slash on purpose: the task normalizes the prefix.
run_download "restricted-resources/pr123" "elm edge-icell-1 edge-icell-2"
if [[ "${STEP_RC}" -ne 0 ]]; then
  echo "${STEP_OUT}"
  fail "components run failed (rc ${STEP_RC})"
fi
assert_aws_args "[s3][cp][s3://test-bucket/restricted-resources/pr123/][${DL_DIR}/][--endpoint-url][https://s3.example.test:443][--no-verify-ssl][--recursive][--exclude][*][--include][elm/*][--include][edge-icell-1/*][--include][edge-icell-2/*]"
assert_extracted "${RBAC_OUT}" \
  "00_elm_Edge_Lifecycle_Management" \
  "20_edge-icell-1_Edge_Integration_Cell" \
  "20_edge-icell-2_Edge_Integration_Cell"
assert_marker "${RBAC_OUT}/00_elm_Edge_Lifecycle_Management/marker.txt" "pr123 elm"
assert_marker "${RBAC_OUT}/20_edge-icell-2_Edge_Integration_Cell/marker.txt" "pr123 edge-icell-2"
[[ ! -e "${DL_DIR}/edge-icell-3" ]] || fail "unlisted folder edge-icell-3 was downloaded"
echo "✅ PASS: components_download_only_listed_folders"

echo ""
echo "Test: topology_b_components"
echo "--------------------------------------------"

run_download "restricted-resources/pr124-multi-stack/" "elm-1 edge-icell-1"
if [[ "${STEP_RC}" -ne 0 ]]; then
  echo "${STEP_OUT}"
  fail "topology B run failed (rc ${STEP_RC})"
fi
assert_aws_args "[s3][cp][s3://test-bucket/restricted-resources/pr124-multi-stack/][${DL_DIR}/][--endpoint-url][https://s3.example.test:443][--no-verify-ssl][--recursive][--exclude][*][--include][elm-1/*][--include][edge-icell-1/*]"
assert_extracted "${RBAC_OUT}" \
  "00_elm-1_Edge_Lifecycle_Management" \
  "20_edge-icell-1_Edge_Integration_Cell"
assert_marker "${RBAC_OUT}/00_elm-1_Edge_Lifecycle_Management/marker.txt" "pr124 elm-1"
echo "✅ PASS: topology_b_components"

echo ""
echo "Test: missing_component_folder_fails"
echo "--------------------------------------------"

run_download "restricted-resources/pr123/" "elm edge-icell-1 edge-icell-9"
if [[ "${STEP_RC}" -eq 0 ]]; then
  echo "${STEP_OUT}"
  fail "a required folder without a zip must fail the task"
fi
if ! grep -qF "No bundle zip in required component folder(s): edge-icell-9" <<< "${STEP_OUT}"; then
  echo "${STEP_OUT}"
  fail "missing-folder error does not name edge-icell-9"
fi
if ! grep -qF "s3://test-bucket/restricted-resources/pr123/<folder>/" <<< "${STEP_OUT}"; then
  echo "${STEP_OUT}"
  fail "missing-folder error does not show the upload location"
fi
[[ -z "$(extracted_dirs "${RBAC_OUT}")" ]] || fail "nothing may be extracted when a folder is missing"
echo "✅ PASS: missing_component_folder_fails"

echo ""
echo "Test: flat_prefix_without_top_level_zips_fails"
echo "--------------------------------------------"

run_download "restricted-resources/pr123/" ""
if [[ "${STEP_RC}" -eq 0 ]]; then
  echo "${STEP_OUT}"
  fail "a flat prefix with only subfolders must fail (nothing to apply)"
fi
if ! grep -qF "list them in requiredComponents" <<< "${STEP_OUT}"; then
  echo "${STEP_OUT}"
  fail "flat-prefix error does not point at requiredComponents"
fi
[[ -z "$(extracted_dirs "${RBAC_OUT}")" ]] || fail "nothing may be extracted from subfolders of a flat prefix"
echo "✅ PASS: flat_prefix_without_top_level_zips_fails"

echo ""
echo "✅ ALL TESTS PASSED"
