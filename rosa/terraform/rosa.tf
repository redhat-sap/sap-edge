# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

module "rosa-hcp" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.6.2"

  cluster_name           = var.cluster_name
  openshift_version      = var.rosa_version
  machine_cidr           = module.vpc[0].vpc_cidr_block
  aws_subnet_ids         = concat(module.vpc[0].private_subnets, module.vpc[0].public_subnets)
  aws_availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
  replicas               = 3
  compute_machine_type   = var.compute_machine_type

  # IAM Role Configuration
  # Account roles: Pre-existing (created once per AWS account with rosa CLI)
  #   rosa create account-roles --prefix ManagedOpenShift --mode auto --yes
  #
  # OIDC + Operator roles: Created per cluster (cluster-specific)
  # These are created/destroyed with each cluster deployment
  create_account_roles  = var.create_account_roles
  account_role_prefix   = var.account_role_prefix
  create_oidc           = var.create_oidc
  oidc_config_id        = var.oidc_config_id
  create_operator_roles = var.create_operator_roles
  operator_role_prefix  = var.operator_role_prefix != "" ? var.operator_role_prefix : var.cluster_name

  # ROSA classifies a subnet as public only if it routes to an internet
  # gateway. Passing just the subnet IDs lets Terraform request the cluster
  # before the internet gateway and routes exist; ROSA then sees only private
  # subnets ("Availability zone ... has more than one private subnet").
  depends_on = [module.vpc]
}
