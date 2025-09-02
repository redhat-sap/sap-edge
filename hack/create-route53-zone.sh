#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Script to create a Route53 hosted zone

set -euo pipefail

# Get domain name from terraform or command line argument
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../rosa/terraform"

# Check if domain is provided as argument first
DOMAIN="${1:-}"

# If no argument provided, try to get from terraform
if [ -z "${DOMAIN}" ]; then
    if [ -d "${TERRAFORM_DIR}" ] && [ -f "${TERRAFORM_DIR}/terraform.tfvars" ]; then
        cd "${TERRAFORM_DIR}"
        DOMAIN=$(terraform output -raw domain_name 2>/dev/null || echo "")
    fi
fi

if [ -z "${DOMAIN}" ]; then
    echo "Usage: $0 <domain-name>"
    echo "Or configure domain_name in terraform.tfvars and run terraform apply first"
    exit 1
fi

echo "Creating Route53 hosted zone for domain: ${DOMAIN}"

# Create the hosted zone
if ZONE_OUTPUT=$(aws route53 create-hosted-zone \
  --name "${DOMAIN}" \
  --caller-reference "$(date +%s)" \
  --hosted-zone-config Comment="Hosted zone for ROSA cluster" \
  --output json \
  2>&1); then
  ZONE_ID=$(echo "${ZONE_OUTPUT}" | jq -r '.HostedZone.Id')
  echo "Successfully created hosted zone with ID: ${ZONE_ID}"
  echo ""
  echo "Name servers for the domain (update these at your domain registrar):"
  echo "${ZONE_OUTPUT}" | jq -r '.DelegationSet.NameServers[]'
else
  echo "Error creating hosted zone:"
  echo "${ZONE_OUTPUT}"
  exit 1
fi
