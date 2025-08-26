#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Script to create a Route53 hosted zone

DOMAIN="${1:-${ROSA_DOMAIN}}"

if [ -z "${DOMAIN}" ]; then
  echo "Usage: $0 <domain-name>"
  echo "Or set ROSA_DOMAIN environment variable"
  exit 1
fi

echo "Creating Route53 hosted zone for domain: ${DOMAIN}"

# Create the hosted zone
if ZONE_OUTPUT=$(aws route53 create-hosted-zone \
  --name "${DOMAIN}" \
  --caller-reference "$(date +%s)" \
  --hosted-zone-config Comment="Hosted zone for ROSA cluster" \
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
