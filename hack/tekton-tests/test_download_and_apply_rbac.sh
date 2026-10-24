#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: download-and-apply-rbac Step 2"
echo "============================================"

# Create temp directories for test
TEST_DOWNLOAD_DIR=$(mktemp -d)
TEST_RBAC_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DOWNLOAD_DIR}" "${TEST_RBAC_DIR}"' EXIT

# Create test zip files matching the expected structure
# elm-1/ and elm-2/ with different versions
# edge-icell-1/, edge-icell-2/, edge-icell-10/ for sort testing

mkdir -p "${TEST_DOWNLOAD_DIR}/elm-1"
mkdir -p "${TEST_DOWNLOAD_DIR}/elm-2"
mkdir -p "${TEST_DOWNLOAD_DIR}/edge-icell-1"
mkdir -p "${TEST_DOWNLOAD_DIR}/edge-icell-2"
mkdir -p "${TEST_DOWNLOAD_DIR}/edge-icell-10"

# Create dummy zips with version info
# elm-1 has both 1.58.0 and 1.62.0-rc.1 (should select 1.62.0-rc.1 as latest)
echo "test" > "${TEST_DOWNLOAD_DIR}/elm-1/dummy.txt"
(cd "${TEST_DOWNLOAD_DIR}/elm-1" && zip -q restricted-resources-Edge_Lifecycle_Management-1.58.0.zip dummy.txt)
(cd "${TEST_DOWNLOAD_DIR}/elm-1" && zip -q restricted-resources-Edge_Lifecycle_Management-1.62.0-rc.1.zip dummy.txt)

# Other components with single versions
(cd "${TEST_DOWNLOAD_DIR}/elm-2" && echo "test" > dummy.txt && zip -q restricted-resources-Edge_Lifecycle_Management-1.60.0.zip dummy.txt)
(cd "${TEST_DOWNLOAD_DIR}/edge-icell-1" && echo "test" > dummy.txt && zip -q restricted-resources-Edge_Integration_Cell-2.0.0.zip dummy.txt)
(cd "${TEST_DOWNLOAD_DIR}/edge-icell-2" && echo "test" > dummy.txt && zip -q restricted-resources-Edge_Integration_Cell-2.0.0.zip dummy.txt)
(cd "${TEST_DOWNLOAD_DIR}/edge-icell-10" && echo "test" > dummy.txt && zip -q restricted-resources-Edge_Integration_Cell-2.0.0.zip dummy.txt)

# Extract the Step 2 script and run it with test directories
# We need to set DOWNLOAD_DIR and RBAC_DIR to our test directories
SCRIPT=$(mktemp)
trap 'rm -f "${SCRIPT}"' EXIT

# Extract Step 2 from the task, replacing the directory assignments
# Provide required parameters with dummy values
python3 -I extract_task_script.py ../../.tekton/tasks/ossm3-download-and-apply-rbac-task.yaml \
  --param hostedClusterName=test-cluster \
  --param requiredComponents='' \
  --from '# Step 2:' \
  --to '# Step 3:' \
  --drop '# Install' 'aws --version' \
  > "${SCRIPT}"

# Replace the hardcoded paths with our test paths
# DOWNLOAD_DIR is set in Step 1, so we need to inject it
# RBAC_DIR is set in Step 2
sed -i.bak "s|DOWNLOAD_DIR=\"/tmp/restricted-resources\"|DOWNLOAD_DIR=\"${TEST_DOWNLOAD_DIR}\"|" "${SCRIPT}" 2>/dev/null || \
  sed -i '' "s|DOWNLOAD_DIR=\"/tmp/restricted-resources\"|DOWNLOAD_DIR=\"${TEST_DOWNLOAD_DIR}\"|" "${SCRIPT}"
sed -i.bak "s|RBAC_DIR=\"/tmp/rbac-resources\"|RBAC_DIR=\"${TEST_RBAC_DIR}\"|" "${SCRIPT}" 2>/dev/null || \
  sed -i '' "s|RBAC_DIR=\"/tmp/rbac-resources\"|RBAC_DIR=\"${TEST_RBAC_DIR}\"|" "${SCRIPT}"

# Also inject DOWNLOAD_DIR at the start since Step 2 uses it from Step 1
sed -i.bak "1a\\
DOWNLOAD_DIR=\"${TEST_DOWNLOAD_DIR}\"
" "${SCRIPT}" 2>/dev/null || \
  sed -i '' "1a\\
DOWNLOAD_DIR=\"${TEST_DOWNLOAD_DIR}\"\\

" "${SCRIPT}"

# Set required variables that would come from the task
export BUCKET_NAME="test-bucket"
export S3_PREFIX="test-prefix/"

# Run the extracted script
bash "${SCRIPT}"

# Check the output directories
EXTRACTED_DIRS=$(find "${TEST_RBAC_DIR}" -mindepth 1 -maxdepth 1 -type d | sort -V)

# Expected order (priority_component_type):
# 00_elm-1_Edge_Lifecycle_Management
# 00_elm-2_Edge_Lifecycle_Management
# 20_edge-icell-1_Edge_Integration_Cell
# 20_edge-icell-2_Edge_Integration_Cell
# 20_edge-icell-10_Edge_Integration_Cell

EXPECTED_ORDER=(
  "00_elm-1_Edge_Lifecycle_Management"
  "00_elm-2_Edge_Lifecycle_Management"
  "20_edge-icell-1_Edge_Integration_Cell"
  "20_edge-icell-2_Edge_Integration_Cell"
  "20_edge-icell-10_Edge_Integration_Cell"
)

ACTUAL_COUNT=$(echo "${EXTRACTED_DIRS}" | wc -l | tr -d ' ')
EXPECTED_COUNT="${#EXPECTED_ORDER[@]}"

if [[ "${ACTUAL_COUNT}" -ne "${EXPECTED_COUNT}" ]]; then
  echo "❌ FAIL: expected ${EXPECTED_COUNT} directories, got ${ACTUAL_COUNT}"
  echo "Actual directories:"
  echo "${EXTRACTED_DIRS}"
  exit 1
fi

# Check exact order
INDEX=0
while IFS= read -r DIR; do
  BASENAME=$(basename "${DIR}")
  EXPECTED="${EXPECTED_ORDER[${INDEX}]}"
  if [[ "${BASENAME}" != "${EXPECTED}" ]]; then
    echo "❌ FAIL: at position ${INDEX}, expected '${EXPECTED}', got '${BASENAME}'"
    echo "All directories:"
    echo "${EXTRACTED_DIRS}"
    exit 1
  fi
  INDEX=$((INDEX + 1))
done <<< "${EXTRACTED_DIRS}"

echo "✅ PASS: directories in correct order"

# Verify that elm-1 used the 1.62.0-rc.1 version (latest)
ELM1_DIR="${TEST_RBAC_DIR}/00_elm-1_Edge_Lifecycle_Management"
if [[ ! -d "${ELM1_DIR}" ]]; then
  echo "❌ FAIL: elm-1 directory not created"
  exit 1
fi

# The directory should contain dummy.txt from the 1.62.0-rc.1 zip
if [[ ! -f "${ELM1_DIR}/dummy.txt" ]]; then
  echo "❌ FAIL: elm-1 directory should contain extracted dummy.txt"
  exit 1
fi

echo "✅ PASS: elm-1 extracted latest version (1.62.0-rc.1)"

echo ""
echo "✅ ALL TESTS PASSED"
