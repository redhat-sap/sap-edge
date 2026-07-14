# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-FileContributor: Rishabh Bhandari (@RishabhKodes)

# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-north-1"
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "rosa-vpc"
}

variable "cluster_name" {
  description = "Name of the cluster (max 15 characters)"
  type        = string
  default     = "rosa-hcp-test"
  
  validation {
    condition     = length(var.cluster_name) <= 15
    error_message = "Cluster name must be 15 characters or less."
  }
}

variable "rosa_version" {
  type        = string
  description = "ROSA openshift version"
  default     = "4.20.12"
}

variable "compute_machine_type" {
  type        = string
  description = "AWS instance type for ROSA worker nodes (e.g., m5.xlarge, m5.2xlarge)"
  default     = "m5.2xlarge"
  
  validation {
    condition     = can(regex("^[a-z][0-9][a-z]?\\.[a-z0-9]+$", var.compute_machine_type))
    error_message = "Compute machine type must be a valid AWS instance type (e.g., m5.2xlarge)."
  }
}

###########################################
# ROSA IAM Role Configuration
###########################################
# By default, use pre-existing account roles to avoid lifecycle issues.
# Create roles once with:
#   rosa create account-roles --prefix ManagedOpenShift --mode auto --yes
#   rosa create oidc-config --mode auto --yes

variable "create_account_roles" {
  description = "Create account-wide IAM roles (HCP-ROSA-Installer, Support, Worker). Set to false to use pre-existing roles."
  type        = bool
  default     = false
}

variable "account_role_prefix" {
  description = "Prefix for account IAM roles. Use 'ManagedOpenShift' for pre-created roles."
  type        = string
  default     = "ManagedOpenShift"
}

variable "create_oidc" {
  description = "Create OIDC provider per cluster. Set to true for pipeline deployments."
  type        = bool
  default     = true
}

variable "oidc_config_id" {
  description = "Pre-existing OIDC config ID (only used when create_oidc=false). Get it with: rosa list oidc-config"
  type        = string
  default     = null
}

variable "create_operator_roles" {
  description = "Create operator IAM roles per cluster. Set to true for pipeline deployments (operator roles are cluster-specific)."
  type        = bool
  default     = true
}

variable "operator_role_prefix" {
  description = "Prefix for operator IAM roles. Use cluster_name for per-cluster roles."
  type        = string
  default     = ""  # Will use cluster_name if empty
}

variable "redhat_ocm_token" {
  description = "Red Hat OpenShift Cluster Manager token"
  type        = string
  sensitive   = true
}

variable "tags" {
  default = {
    Terraform   = "true"
    Environment = "test"
  }
  description = "Tags for created AWS resources"
  type        = map(string)
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

###########################################
# AWS Services Variables
###########################################

variable "deploy_postgres" {
  description = "Deploy AWS RDS PostgreSQL"
  type        = bool
  default     = false  # Disabled by default - enable with TF_VAR_deploy_postgres=true
}

variable "deploy_redis" {
  description = "Deploy AWS ElastiCache Redis"
  type        = bool
  default     = false  # Disabled by default - enable with TF_VAR_deploy_redis=true
}

variable "deploy_quay" {
  description = "Deploy S3 bucket for Quay registry storage"
  type        = bool
  default     = true  # Enabled by default for Quay deployment
}

# PostgreSQL Configuration
variable "postgres_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15.14"  # Latest stable PostgreSQL 15.x available in eu-north-1
}

variable "postgres_instance_class" {
  description = "RDS instance class (cost-optimized for testing)"
  type        = string
  default     = "db.t3.micro"
}

variable "postgres_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "postgres_admin_username" {
  description = "PostgreSQL admin username"
  type        = string
  default     = "eicadmin"
}

variable "postgres_admin_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
  default     = ""  # Set via TF_VAR_postgres_admin_password or terraform.tfvars
  
  validation {
    condition     = var.postgres_admin_password == "" || can(regex("^[^/@\" ]+$", var.postgres_admin_password))
    error_message = "PostgreSQL password cannot contain these characters: / @ \" (space). Use letters, numbers, and these special characters: ! # $ % & ( ) * + , - . : ; < = > ? [ \\ ] ^ _ ` { | } ~"
  }
  
  validation {
    condition     = var.postgres_admin_password == "" || length(var.postgres_admin_password) >= 8
    error_message = "PostgreSQL password must be at least 8 characters long."
  }
}

variable "postgres_publicly_accessible" {
  description = "Make PostgreSQL publicly accessible"
  type        = bool
  default     = false
}

variable "postgres_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access PostgreSQL"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

# Redis Configuration
variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.0"
}

variable "redis_node_type" {
  description = "ElastiCache node type (cost-optimized for testing)"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access Redis"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}
