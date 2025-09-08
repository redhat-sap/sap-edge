# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

module "rosa-hcp" {
  source                 = "terraform-redhat/rosa-hcp/rhcs"
  version                = "1.6.9"
  cluster_name           = var.cluster_name
  openshift_version      = var.rosa_version
  account_role_prefix    = var.cluster_name
  operator_role_prefix   = var.cluster_name
  replicas               = 3
  aws_availability_zones = slice([for zone in data.aws_availability_zones.available.names : format("%s", zone)], 0, 3)
  create_oidc            = true
  private                = true
  aws_subnet_ids         = concat(var.private_subnets, var.public_subnets)
  create_account_roles   = true
  create_operator_roles  = true
}
