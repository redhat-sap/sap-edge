# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-FileContributor: Rishabh Bhandari (@RishabhKodes)

# SPDX-License-Identifier: Apache-2.0

terraform {
  backend "s3" {
    bucket         = ""
    key            = ""
    region         = ""
    encrypt        = true
    dynamodb_table = ""

  }
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
    tags = var.tags
  }
}

provider "rhcs" {
  url = "https://api.openshift.com"
}
