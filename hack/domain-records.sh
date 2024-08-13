#! /usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

DOMAIN=""
ARO_NAME=""
ARO_RESOURCE_GROUP=""

print_help() {
  echo "Usage: $0 --domain DOMAIN --aro-name NAME --aro-resource-group GROUP"
  echo
  echo "Options:"
  echo "  --domain DOMAIN             Specify the domain"
  echo "  --aro-name NAME             Specify the ARO cluster name"
  echo "  --aro-resource-group GROUP  Specify the ARO resource group"
  exit 1
}

# Process command-line arguments
while (( "$#" )); do
  case "$1" in
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --aro-name)
      ARO_NAME="$2"
      shift 2
      ;;
    --aro-resource-group)
      ARO_RESOURCE_GROUP="$2"
      shift 2
      ;;
    *)
      echo "Error: Invalid argument"
      print_help
  esac
done

if [ -z "$DOMAIN" ] || [ -z "$ARO_NAME" ] || [ -z "$ARO_RESOURCE_GROUP" ]; then
  echo "Error: Missing argument"
  print_help
fi

if ! [ "$(az resource show --name "${ARO_CLUSTER_NAME}" \
  --resource-group "${ARO_RESOURCE_GROUP}" \
  --resource-type 'Microsoft.RedHatOpenShift/openShiftClusters' \
  --query "id" -o tsv)" ]; then
    echo "ARO does not exists"
fi

API_IP=$(az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" \
  --query 'apiserverProfile.ip' -o tsv)

INGRESS_IP=$(az aro show --name "${ARO_CLUSTER_NAME}" --resource-group "${ARO_RESOURCE_GROUP}" \
  --query 'ingressProfiles[0].ip' -o tsv)

echo Create domain records for existing OpenShift cluster

az deployment group create \
  --resource-group "$(az network dns zone list --query "[?name=='saponrhel.org'].resourceGroup" -o tsv)" \
  --template-file bicep/domain-records.bicep \
  --parameters \
  domainZoneName="${DOMAIN}" \
  recordName='api' \
  ipv4Address="${API_IP}"

az deployment group create \
  --resource-group "$(az network dns zone list --query "[?name=='saponrhel.org'].resourceGroup" -o tsv)" \
  --template-file bicep/domain-records.bicep \
  --parameters \
  domainZoneName="${DOMAIN}" \
  recordName='*.apps' \
  ipv4Address="${INGRESS_IP}"

