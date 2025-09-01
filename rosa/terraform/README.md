%% SPDX-FileCopyrightText: 2025 SAP edge team
%% SPDX-FileContributor: Kirill Satarin (@kksat)
%% SPDX-FileContributor: Manjun Jiao (@mjiao)
%% SPDX-FileContributor: Rishabh Bhandari (@RishabhKodes)
%%
%% SPDX-License-Identifier: Apache-2.0

# ROSA Terraform Infrastructure

This directory contains Terraform configuration files for provisioning AWS infrastructure required for Red Hat OpenShift Service on AWS (ROSA) clusters.

## Overview

The infrastructure creates a highly available VPC with public and private subnets across 3 availability zones, designed to support ROSA cluster deployment. The configuration uses both AWS and Red Hat Cloud Services (RHCS) providers.

## Architecture

### Network Design
- **VPC**: Single VPC with configurable CIDR block
- **Subnets**: 6 subnets total across 3 availability zones:
  - 3 public subnets
  - 3 private subnets
- **NAT Gateways**: One NAT gateway per availability zone for private subnet internet access
- **Internet Gateway**: Single IGW for public subnet internet access
- See default parameters in variables.tf file

## Files

| File | Purpose |
|------|---------|
| `provider.tf` | Provider configurations for AWS and RHCS, including backend configuration |
| `variables.tf` | Variable definitions with descriptions and default values |
| `network.tf` | VPC, subnets, route tables, NAT gateways, and networking resources |
| `outputs.tf` | Output definitions |
| `backend.config` | S3 backend configuration for state management |

## Prerequisites

1. **Terraform**: Version >= 1.4.6
2. **AWS CLI**: Configured with appropriate credentials
3. **RHCS Token**: Red Hat Cloud Services token for OpenShift API access
4. **S3 Backend**: Existing S3 bucket and DynamoDB table for state management

## Configuration

### Required Variables

Set these variables in `.env` file or as environment variables:

```.env
CLUSTER_NAME="your-cluster-name"
AWS_REGION="your-aws-region"
VPC_NAME="your-vpc-name"
TF_VARS_admin_username="kubeadmin"
TF_VARS_admin_password=""
TERRAFORM_BACKEND_S3_BUCKET=
TERRAFORM_BACKEND_S3_KEY=
TERRAFORM_BACKEND_S3_AWS_REGION=
TERRAFORM_BACKEND_S3_DYNAMODB_TABLE=
```

### Optional Variables

All subnet CIDR blocks and environment tag can be customized. See `variables.tf` for defaults.

## Usage

1. **Initialize Terraform**:
   ```bash
   make rosa-terraform-init
   ```

2. **Plan deployment**:
   ```bash
   make rosa-terraform-plan
   ```

3. **Apply configuration**: (not implemented yet)
   ```bash
   make rosa-terraform-apply
   ```

4. **Destroy infrastructure** (not implemented yet):
   ```bash
   make rosa-terraform-destroy
   ```

## License

Apache-2.0
