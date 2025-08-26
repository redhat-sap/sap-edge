# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# EFS File System
resource "aws_efs_file_system" "rosa_efs" {
  count = var.enable_efs ? 1 : 0

  creation_token = "${var.cluster_name}-efs-${data.aws_caller_identity.current.account_id}"
  encrypted      = true
  kms_key_id     = var.efs_kms_key_arn != "" ? var.efs_kms_key_arn : null

  performance_mode                = var.efs_performance_mode
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_throughput_mode == "provisioned" ? var.efs_provisioned_throughput : null

  lifecycle_policy {
    transition_to_ia = var.efs_transition_to_ia
  }

  lifecycle_policy {
    transition_to_primary_storage_class = var.efs_transition_to_primary_storage_class
  }

  tags = merge(
    var.additional_tags,
    {
      Name        = "${var.cluster_name}-efs"
      Environment = var.environment_tag
      ManagedBy   = "terraform"
    }
  )
}

# Security Group for EFS
resource "aws_security_group" "efs" {
  count = var.enable_efs ? 1 : 0

  name        = "${var.cluster_name}-efs-sg"
  description = "Security group for EFS mount targets"
  vpc_id      = var.create_vpc ? aws_vpc.main.id : data.aws_vpc.existing[0].id

  tags = merge(
    var.additional_tags,
    {
      Name        = "${var.cluster_name}-efs-sg"
      Environment = var.environment_tag
    }
  )
}

# Security Group Rule for NFS
resource "aws_security_group_rule" "efs_ingress" {
  count = var.enable_efs ? 1 : 0

  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.efs[0].id
  security_group_id        = aws_security_group.efs[0].id
  description              = "Allow NFS traffic from within the security group"
}

# Security Group Rule for Worker Nodes
resource "aws_security_group_rule" "efs_from_workers" {
  count = var.enable_efs ? 1 : 0

  type              = "ingress"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.efs[0].id
  description       = "Allow NFS traffic from VPC CIDR"
}

# Get the private subnets for mount targets
locals {
  # Use either created subnets or existing ones
  private_subnet_ids = var.create_vpc ? [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ] : var.existing_subnet_ids

  # Filter out only private subnets if using existing ones
  mount_target_subnet_ids = var.create_vpc ? local.private_subnet_ids : [
    for subnet_id in var.existing_subnet_ids : subnet_id
    if can(regex("private", data.aws_subnet.existing[subnet_id].tags["Name"]))
  ]
}

# Data source for existing VPC (when not creating VPC)
data "aws_vpc" "existing" {
  count = var.create_vpc ? 0 : 1

  filter {
    name   = "tag:Name"
    values = ["*${var.cluster_name}*"]
  }
}

# Data source for existing subnets (when not creating VPC)
data "aws_subnet" "existing" {
  for_each = var.create_vpc ? toset([]) : toset(var.existing_subnet_ids)
  id       = each.value
}

# EFS Mount Targets
resource "aws_efs_mount_target" "rosa_efs" {
  for_each = var.enable_efs ? toset(local.mount_target_subnet_ids) : toset([])

  file_system_id  = aws_efs_file_system.rosa_efs[0].id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs[0].id]
}

# IAM Policy for EFS CSI Driver
resource "aws_iam_policy" "efs_csi_driver" {
  count = var.enable_efs ? 1 : 0

  name        = "${var.cluster_name}-rosa-efs-csi"
  path        = var.iam_role_path
  description = "Policy for EFS CSI Driver on ROSA cluster ${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:TagResource",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:CreateAccessPoint"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "elasticfilesystem:DeleteAccessPoint"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      }
    ]
  })

  tags = merge(
    var.additional_tags,
    {
      Name        = "${var.cluster_name}-efs-csi-policy"
      Environment = var.environment_tag
    }
  )
}

# For EFS CSI driver, we need the OIDC provider information
# We'll use the existing OIDC provider that was created for the ROSA cluster
# The OIDC endpoint URL should be provided via variables or detected from existing resources
locals {
  # When using existing OIDC, we need the full endpoint URL
  # For new OIDC creation, this would be populated after the ROSA module runs
  oidc_endpoint = var.oidc_endpoint_url != "" ? var.oidc_endpoint_url : "oidc.op1.openshiftapps.com/${var.oidc_config_id}"

  # Construct the OIDC provider ARN
  oidc_provider_arn = var.enable_efs ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_endpoint}" : ""

  # Extract just the host/path for the trust policy condition
  oidc_provider_host = var.enable_efs ? local.oidc_endpoint : ""
}

# IAM Role for EFS CSI Driver
resource "aws_iam_role" "efs_csi_driver" {
  count = var.enable_efs ? 1 : 0

  name               = "${var.cluster_name}-aws-efs-csi-operator"
  path               = var.iam_role_path
  permissions_boundary = var.iam_role_permissions_boundary != "" ? var.iam_role_permissions_boundary : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_host}:sub" = [
              "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-operator",
              "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa"
            ]
          }
        }
      }
    ]
  })

  tags = merge(
    var.additional_tags,
    {
      Name        = "${var.cluster_name}-efs-csi-role"
      Environment = var.environment_tag
    }
  )
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  count = var.enable_efs ? 1 : 0

  policy_arn = aws_iam_policy.efs_csi_driver[0].arn
  role       = aws_iam_role.efs_csi_driver[0].name
}

# Output the EFS and role details
output "efs_file_system_id" {
  description = "ID of the EFS file system"
  value       = var.enable_efs ? aws_efs_file_system.rosa_efs[0].id : ""
}

output "efs_file_system_dns" {
  description = "DNS name of the EFS file system"
  value       = var.enable_efs ? aws_efs_file_system.rosa_efs[0].dns_name : ""
}

output "efs_csi_driver_role_arn" {
  description = "ARN of the IAM role for EFS CSI driver"
  value       = var.enable_efs ? aws_iam_role.efs_csi_driver[0].arn : ""
}

output "efs_security_group_id" {
  description = "ID of the security group for EFS"
  value       = var.enable_efs ? aws_security_group.efs[0].id : ""
}
