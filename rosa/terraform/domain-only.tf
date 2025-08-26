# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# This file can be used independently when you only need to manage domain records
# without the network infrastructure
# Note: When used standalone, add the terraform block with required_providers

# terraform {
#   required_version = ">= 1.0"
#
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#   }
# }

# Use this file with domain-specific variables only
# Example usage:
# terraform init
# terraform apply -var="cluster_name=my-cluster" -var="domain_name=example.com" -var="use_cname_records=true" -var="api_target=api.cluster.com" -var="ingress_target=apps.cluster.com"
