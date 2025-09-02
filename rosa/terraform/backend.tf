# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# S3 Backend Configuration for Terraform State
# This configuration stores the Terraform state file in S3, enabling
# state sharing across team members and devices.

terraform {
  backend "s3" {
    # S3 bucket name for storing state files
    bucket = "sap-edge-terraform-state"

    # The path within the bucket where the state file will be stored
    key = "rosa/terraform.tfstate"

    # AWS region where the S3 bucket is located
    region = "eu-central-1"

    # Enable state file encryption at rest
    encrypt = true

    # DynamoDB table for state locking (prevents concurrent modifications)
    # This table must have a primary key named "LockID"
    dynamodb_table = "terraform-state-lock"
  }
}
