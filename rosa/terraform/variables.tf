# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the ROSA cluster"
  type        = string
  default     = "sapeic-cluster"
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "rosa-vpc"
}

variable "environment_tag" {
  description = "Environment tag value"
  type        = string
  default     = "rosa"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_1_cidr" {
  description = "CIDR block for public subnet 1"
  type        = string
  default     = "10.0.0.0/24"
}

variable "public_subnet_2_cidr" {
  description = "CIDR block for public subnet 2"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_1_cidr" {
  description = "CIDR block for private subnet 1"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnet_2_cidr" {
  description = "CIDR block for private subnet 2"
  type        = string
  default     = "10.0.3.0/24"
}

variable "public_subnet_3_cidr" {
  description = "CIDR block for public subnet 3"
  type        = string
  default     = "10.0.4.0/24"
}

variable "private_subnet_3_cidr" {
  description = "CIDR block for private subnet 3"
  type        = string
  default     = "10.0.5.0/24"
}

# Domain variables
variable "domain_name" {
  description = "The domain name for Route53 records"
  type        = string
  default     = ""
}

variable "api_target" {
  description = "Target for API CNAME record"
  type        = string
  default     = ""
}

variable "ingress_target" {
  description = "Target for ingress CNAME record"
  type        = string
  default     = ""
}

variable "ipv4_address" {
  description = "IPv4 address for A records"
  type        = string
  default     = ""
}

# ROSA HCP Variables
variable "rosa_version" {
  description = "OpenShift version for ROSA cluster"
  type        = string
  default     = "4.14.24"
}

variable "channel_group" {
  description = "Channel group for the cluster version (stable, candidate, fast, or nightly)"
  type        = string
  default     = "stable"
}

variable "worker_replicas" {
  description = "Number of worker node replicas"
  type        = number
  default     = 3
}

variable "worker_machine_type" {
  description = "AWS instance type for worker nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "create_vpc" {
  description = "Whether to create a new VPC or use existing subnets"
  type        = bool
  default     = true
}

variable "existing_subnet_ids" {
  description = "List of existing subnet IDs to use when create_vpc is false"
  type        = list(string)
  default     = []
}

variable "availability_zones" {
  description = "List of availability zones to use. If empty, will use all available AZs"
  type        = list(string)
  default     = []
}

# STS Configuration
variable "create_account_roles" {
  description = "Whether to create account-wide IAM roles"
  type        = bool
  default     = true
}

variable "account_role_prefix" {
  description = "Prefix for account-wide IAM roles. If empty, uses cluster_name-account"
  type        = string
  default     = ""
}

variable "create_oidc" {
  description = "Whether to create OIDC provider"
  type        = bool
  default     = true
}

variable "oidc_endpoint_url" {
  description = "OIDC endpoint URL (if using existing OIDC provider)"
  type        = string
  default     = ""
}

variable "oidc_config_id" {
  description = "OIDC configuration ID (if using existing OIDC provider)"
  type        = string
  default     = ""
}

variable "create_operator_roles" {
  description = "Whether to create operator IAM roles"
  type        = bool
  default     = true
}

variable "operator_role_prefix" {
  description = "Prefix for operator IAM roles. If empty, uses cluster_name-operator"
  type        = string
  default     = ""
}

variable "iam_role_path" {
  description = "Path for all IAM roles created"
  type        = string
  default     = "/"
}

variable "iam_role_permissions_boundary" {
  description = "ARN of the policy that is used to set the permissions boundary for IAM roles"
  type        = string
  default     = ""
}

# Cluster Configuration
variable "private_cluster" {
  description = "Whether to create a private cluster"
  type        = bool
  default     = false
}

variable "enable_autoscaling" {
  description = "Enable autoscaling for worker nodes"
  type        = bool
  default     = false
}

variable "min_replicas" {
  description = "Minimum number of worker replicas when autoscaling is enabled"
  type        = number
  default     = 2
}

variable "max_replicas" {
  description = "Maximum number of worker replicas when autoscaling is enabled"
  type        = number
  default     = 10
}

variable "kms_key_arn" {
  description = "ARN of KMS key to use for EBS encryption"
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Admin User Configuration
variable "create_admin_user" {
  description = "Whether to create cluster admin user"
  type        = bool
  default     = true
}

variable "admin_username" {
  description = "Username for cluster admin"
  type        = string
  default     = "kubeadmin"
}

variable "admin_password" {
  description = "Password for cluster admin (auto-generated if not provided)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "wait_for_cluster" {
  description = "Wait for the cluster to be ready before completing"
  type        = bool
  default     = true
}

variable "rosa_token" {
  description = "ROSA token for authentication"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dns_ttl" {
  description = "DNS record TTL in seconds"
  type        = number
  default     = 3600
}

variable "create_domain_records" {
  description = "Whether to create Route53 domain records (requires existing hosted zone)"
  type        = bool
  default     = false
}

variable "use_cname_records" {
  description = "Use CNAME records instead of A records"
  type        = bool
  default     = false
}

# EFS Configuration Variables
variable "enable_efs" {
  description = "Whether to create and configure EFS for the ROSA cluster"
  type        = bool
  default     = false
}

variable "efs_performance_mode" {
  description = "Performance mode for EFS (generalPurpose or maxIO)"
  type        = string
  default     = "generalPurpose"
  validation {
    condition     = contains(["generalPurpose", "maxIO"], var.efs_performance_mode)
    error_message = "EFS performance mode must be either 'generalPurpose' or 'maxIO'."
  }
}

variable "efs_throughput_mode" {
  description = "Throughput mode for EFS (bursting, provisioned, or elastic)"
  type        = string
  default     = "bursting"
  validation {
    condition     = contains(["bursting", "provisioned", "elastic"], var.efs_throughput_mode)
    error_message = "EFS throughput mode must be 'bursting', 'provisioned', or 'elastic'."
  }
}

variable "efs_provisioned_throughput" {
  description = "Provisioned throughput in MiB/s (required when throughput_mode is 'provisioned')"
  type        = number
  default     = null
}

variable "efs_kms_key_arn" {
  description = "ARN of KMS key to use for EFS encryption (uses AWS managed key if not specified)"
  type        = string
  default     = ""
}

variable "efs_transition_to_ia" {
  description = "Number of days after which to transition files to Infrequent Access storage class"
  type        = string
  default     = "AFTER_30_DAYS"
  validation {
    condition = contains([
      "AFTER_1_DAY", "AFTER_7_DAYS", "AFTER_14_DAYS", "AFTER_30_DAYS",
      "AFTER_60_DAYS", "AFTER_90_DAYS", "AFTER_180_DAYS", "AFTER_270_DAYS", "AFTER_365_DAYS"
    ], var.efs_transition_to_ia)
    error_message = "Invalid EFS transition to IA value."
  }
}

variable "efs_transition_to_primary_storage_class" {
  description = "Whether to transition files back from IA to primary storage on first access"
  type        = string
  default     = "AFTER_1_ACCESS"
  validation {
    condition     = contains(["AFTER_1_ACCESS", "NONE"], var.efs_transition_to_primary_storage_class)
    error_message = "EFS transition to primary storage class must be 'AFTER_1_ACCESS' or 'NONE'."
  }
}
