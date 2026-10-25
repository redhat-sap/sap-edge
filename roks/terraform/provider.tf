# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

terraform {
  # Terraform state lives in an IBM Cloud Object Storage bucket, reached through
  # the S3-compatible API. This is a partial configuration: bucket, key, region,
  # the COS endpoint, use_lockfile, use_path_style and the skip_* flags are
  # passed at init time with -backend-config (see README.md and roks.makefile).
  backend "s3" {}

  # >= 1.10 for S3-native state locking (use_lockfile).
  required_version = ">= 1.10"

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "~> 2.8.0"
    }
  }
}

# The API key comes from the environment variable IBMCLOUD_API_KEY.
provider "ibm" {
  region = var.region
}
