# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.4.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    rhcs = {
      source  = "terraform-redhat/rhcs"
      version = "~> 1.6.2"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ROSA"
      Environment = var.environment_tag
      ManagedBy   = "Terraform"
    }
  }
}

provider "rhcs" {
  url = "https://api.openshift.com"
}

# Data source for current AWS account ID
data "aws_caller_identity" "current" {}
