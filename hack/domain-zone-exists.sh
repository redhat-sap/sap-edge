#! /usr/bin/env bash

# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

NAME=$(az network dns zone list --query "[?name=='${ARO_DOMAIN}'].name" -o tsv)
if [ "${NAME}" == "${ARO_DOMAIN}" ]; then
  echo "Domain zone ${ARO_DOMAIN} exists"
else
  echo "Domain zone ${ARO_DOMAIN} does not exist"
  exit 1
fi
