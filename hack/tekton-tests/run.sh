#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"

echo "=========================================="
echo "Running Tekton test harness"
echo "=========================================="

# Run all test_*.sh files
for TEST in test_*.sh; do
  echo ""
  echo "Running ${TEST}..."
  bash "${TEST}"
done

echo ""
echo "=========================================="
echo "Running pipeline wiring checker"
echo "=========================================="

# Check all pipelines and run files
# Controller ruling R1: use hcp-ossm3-dedicated-validation-pipeline (not hcp-ossm3-dedicated-validation)
python3 -I check_pipeline.py \
  --cell-gate hcp-ossm3-dedicated-validation-pipeline:cellCount:2 \
  ../../.tekton/pipelines/*.yaml \
  ../../.tekton/*-run.yaml

echo ""
echo "=========================================="
echo "✅ ALL TESTS AND CHECKS PASSED"
echo "=========================================="
