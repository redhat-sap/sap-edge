#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Get domain name from terraform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../rosa/terraform"

if [ ! -d "${TERRAFORM_DIR}" ]; then
    echo "Error: Terraform directory not found at ${TERRAFORM_DIR}"
    exit 1
fi

cd "${TERRAFORM_DIR}"

# Check if terraform state exists and get domain name
if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
    echo "No terraform state found. Terraform has not been initialized or applied yet."
    echo "Run 'terraform init' and 'terraform apply' first."
    exit 1
fi

ROSA_DOMAIN=$(terraform output -raw domain_name 2>/dev/null)
if [ -z "${ROSA_DOMAIN}" ]; then
    echo "Error: Could not get domain_name from terraform output"
    echo "Make sure terraform has been applied successfully and domain_name is configured"
    exit 1
fi

# Check if the Route53 hosted zone exists for the domain
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --query "HostedZones[?Name=='${ROSA_DOMAIN}.'].Id" \
  --output text 2>/dev/null)

if [ -n "${ZONE_ID}" ]; then
  echo "Domain zone ${ROSA_DOMAIN} exists with ID: ${ZONE_ID}"
else
  echo "Error: Domain zone ${ROSA_DOMAIN} does not exist in Route53"
  echo "Please create a hosted zone for ${ROSA_DOMAIN} in AWS Route53 before proceeding"
  exit 1
fi
