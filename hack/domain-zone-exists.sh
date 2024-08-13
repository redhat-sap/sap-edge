#! /usr/bin/env bash

NAME=$(az network dns zone list --query "[?name=='${ARO_DOMAIN}'].name" -o tsv)
if [ "${NAME}" == "${ARO_DOMAIN}" ]; then
  echo "Domain zone ${ARO_DOMAIN} exists"
else
  echo "Domain zone ${ARO_DOMAIN} does not exist"
  exit 1
fi
