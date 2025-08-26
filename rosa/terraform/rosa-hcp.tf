# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# ROSA HCP Cluster Configuration

# ROSA HCP Cluster Module
module "rosa_hcp" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.6.2"

  # Cluster Configuration
  cluster_name        = var.cluster_name
  openshift_version   = var.rosa_version

  # Network Configuration
  machine_cidr           = var.vpc_cidr
  aws_subnet_ids         = concat(var.create_vpc ? aws_subnet.public_1[*].id : [],
                                  var.create_vpc ? aws_subnet.public_2[*].id : [],
                                  var.create_vpc ? aws_subnet.public_3[*].id : [],
                                  var.create_vpc ? aws_subnet.private_1[*].id : [],
                                  var.create_vpc ? aws_subnet.private_2[*].id : [],
                                  var.create_vpc ? aws_subnet.private_3[*].id : [],
                                  var.existing_subnet_ids)
  aws_availability_zones = var.availability_zones != [] ? var.availability_zones : []

  # Worker Node Configuration
  replicas               = var.worker_replicas
  compute_machine_type   = var.worker_machine_type

  # STS Configuration
  create_account_roles  = var.create_account_roles
  account_role_prefix   = var.account_role_prefix != "" ? var.account_role_prefix : "${var.cluster_name}-account"

  create_oidc           = var.create_oidc
  oidc_endpoint_url     = var.create_oidc ? null : var.oidc_endpoint_url
  oidc_config_id        = var.create_oidc ? null : var.oidc_config_id

  create_operator_roles = var.create_operator_roles
  operator_role_prefix  = var.operator_role_prefix != "" ? var.operator_role_prefix : "${var.cluster_name}-operator"

  # Additional Configuration
  path                  = var.iam_role_path
  permissions_boundary  = var.iam_role_permissions_boundary != "" ? var.iam_role_permissions_boundary : null

  # Cluster access
  private               = var.private_cluster

  # Additional security
  kms_key_arn          = var.kms_key_arn != "" ? var.kms_key_arn : null

  # Tags
  tags = merge(
    var.additional_tags,
    {
      Project     = "ROSA-HCP"
      Environment = var.environment_tag
      ManagedBy   = "Terraform"
    }
  )

  # Properties
  properties = {
    rosa_creator_arn = data.aws_caller_identity.current.arn
  }

  # Wait for cluster to be ready
  wait_for_create_complete = var.wait_for_cluster
}

# Note: If a cluster already exists with the same name:
# 1. Run 'make rosa-cluster-status' to check existing cluster details
# 2. If you want to manage it with Terraform, import it using:
#    terraform import module.rosa_hcp.rhcs_cluster_rosa_hcp.rosa_hcp_cluster <cluster-id>
# 3. Terraform will then manage updates to the existing cluster
