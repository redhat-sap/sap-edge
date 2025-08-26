#!/bin/bash
# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Check ROSA cluster status before terraform deployment

set -euo pipefail

# Load environment variables if .env exists
if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi

# Set default values
CLUSTER_NAME="${CLUSTER_NAME:-sapeic-cluster}"
ROSA_TOKEN="${ROSA_TOKEN:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if ROSA CLI is installed
if ! command -v rosa &> /dev/null; then
    echo -e "${RED}Error: ROSA CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if ROSA token is provided
if [ -z "${ROSA_TOKEN}" ]; then
    echo -e "${RED}Error: ROSA_TOKEN is not set. Please provide it in .env file or as environment variable.${NC}"
    exit 1
fi

# Login to ROSA
echo "Logging in to ROSA..."
rosa login --token="${ROSA_TOKEN}" >/dev/null 2>&1

# Check if cluster exists
echo "Checking for existing cluster: ${CLUSTER_NAME}"
if rosa describe cluster --cluster="${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists!${NC}"
    echo ""
    echo "Current cluster details:"
    CLUSTER_INFO=$(rosa describe cluster --cluster="${CLUSTER_NAME}")
    echo "${CLUSTER_INFO}" | grep -E "^(ID:|Name:|State:|OpenShift Version:|Nodes:|API URL:|Console URL:)"

    # Extract cluster ID for terraform import
    CLUSTER_ID=$(echo "${CLUSTER_INFO}" | grep "^ID:" | awk '{print $2}')

    echo ""
    echo -e "${YELLOW}⚠️  Action Required:${NC}"
    echo ""
    echo "This cluster was created outside of Terraform. To manage it with Terraform:"
    echo ""
    echo "1. First, run terraform init:"
    echo "   ${GREEN}cd rosa/terraform && terraform init${NC}"
    echo ""
    echo "2. Import the existing cluster into Terraform state:"
    echo "   ${GREEN}cd rosa/terraform && terraform import module.rosa_hcp.rhcs_cluster_rosa_hcp.rosa_hcp_cluster ${CLUSTER_ID}${NC}"
    echo ""
    echo "3. Then run terraform plan to see if any changes are needed:"
    echo "   ${GREEN}cd rosa/terraform && terraform plan${NC}"
    echo ""
    echo "Note: Some properties cannot be updated after cluster creation. If Terraform"
    echo "shows changes that cannot be applied, you may need to:"
    echo "- Accept the current configuration, or"
    echo "- Delete and recreate the cluster with the desired configuration"
    exit 0
else
    echo -e "${GREEN}No existing cluster found with name '${CLUSTER_NAME}'.${NC}"
    echo "Terraform will create a new ROSA HCP cluster."
    exit 0
fi
