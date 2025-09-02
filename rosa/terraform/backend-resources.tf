# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# This file defines the S3 bucket and DynamoDB table resources
# required for the Terraform backend. These resources should be
# created before migrating to the S3 backend.

# S3 bucket for storing Terraform state
resource "aws_s3_bucket" "terraform_state" {
  count  = var.create_backend_resources ? 1 : 0
  bucket = var.terraform_state_bucket_name

  tags = merge(
    {
      Name        = "Terraform State Bucket"
      Environment = "shared"
      Purpose     = "terraform-state"
    }
  )
}

# Enable versioning for state file history
resource "aws_s3_bucket_versioning" "terraform_state" {
  count  = var.create_backend_resources ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  count  = var.create_backend_resources ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access to the bucket
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  count  = var.create_backend_resources ? 1 : 0
  bucket = aws_s3_bucket.terraform_state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_state_lock" {
  count        = var.create_backend_resources ? 1 : 0
  name         = var.terraform_state_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = merge(
    {
      Name        = "Terraform State Lock Table"
      Environment = "shared"
      Purpose     = "terraform-state-lock"
    }
  )
}

# Outputs for backend resources
output "terraform_state_bucket_name" {
  value       = var.create_backend_resources ? aws_s3_bucket.terraform_state[0].id : var.terraform_state_bucket_name
  description = "Name of the S3 bucket for Terraform state"
}

output "terraform_state_lock_table_name" {
  value       = var.create_backend_resources ? aws_dynamodb_table.terraform_state_lock[0].id : var.terraform_state_lock_table_name
  description = "Name of the DynamoDB table for state locking"
}
