#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Check if ROSA_DOMAIN is set
if [ -z "${ROSA_DOMAIN}" ]; then
  echo "Error: ROSA_DOMAIN environment variable is not set"
  exit 1
fi

set -o pipefail

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
