#!/bin/bash
# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Check ROSA cluster status before terraform deployment

set -euo pipefail

# Define colors
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Get cluster name from terraform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../rosa/terraform"

if [ ! -d "${TERRAFORM_DIR}" ]; then
    echo "Error: Terraform directory not found at ${TERRAFORM_DIR}"
    exit 1
fi

cd "${TERRAFORM_DIR}"

# Check if terraform state exists and get cluster name
if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
    echo "No terraform state found. Terraform has not been initialized or applied yet."
    echo "Run 'terraform init' and 'terraform apply' first."
    exit 1
fi

CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null)
if [ -z "${CLUSTER_NAME}" ]; then
    echo "Error: Could not get cluster_name from terraform output"
    echo "Make sure terraform has been applied successfully"
    exit 1
fi

# Get ROSA token and login
echo "Logging in to ROSA..."
# Load .env file if it exists
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
fi

if [ -z "${ROSA_TOKEN}" ]; then
    echo -e "${YELLOW}Warning: ROSA_TOKEN not found in environment.${NC}"
    echo "Please set ROSA_TOKEN in .env file."
    echo "Get a fresh token from: https://console.redhat.com/openshift/token"
    echo ""
    echo "Attempting to check cluster status without authentication..."
elif ! rosa login --token="${ROSA_TOKEN}" >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: ROSA login failed. This might be due to an expired or invalid token.${NC}"
    echo "Please update the ROSA_TOKEN in .env file with a fresh token from:"
    echo "https://console.redhat.com/openshift/token"
    echo ""
    echo "Attempting to check cluster status without authentication..."
else
    echo "Successfully logged in to ROSA."
fi

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
