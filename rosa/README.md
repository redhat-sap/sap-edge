<!--
SPDX-FileCopyrightText: 2025 SAP edge team
SPDX-FileContributor: Kirill Satarin (@kksat)
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# ROSA Infrastructure with Terraform

This directory contains Terraform configurations for deploying Red Hat OpenShift Service on AWS (ROSA) clusters with Hosted Control Planes (HCP) architecture.

## Prerequisites

1. **Terraform** >= 1.4.6
2. **AWS CLI** configured with appropriate credentials
3. **OpenShift CLI (oc)** for cluster access
4. **ROSA token** from https://console.redhat.com/openshift/token
5. **jq** for JSON processing
6. **Route53 hosted zone** (optional, for custom domain)

## Quick Start

### 1. Configure Environment

You can configure the deployment using either environment variables or Terraform variables:

#### Option A: Using Environment Variables (Recommended)

Create a `.env` file from the example:

```bash
cd terraform
cp env.example .env
# Edit .env with your configuration
```

Key variables to set in `.env`:

```bash
# Required
ROSA_TOKEN=your-rosa-token-here
CLUSTER_NAME=sapeic-cluster
AWS_REGION=eu-central-1

# Optional
ROSA_VERSION=4.14.24
WORKER_MACHINE_TYPE=m5.xlarge
WORKER_REPLICAS=3
DOMAIN_NAME=your-domain.com  # Optional, requires Route53 hosted zone

# EFS Configuration (optional)
ENABLE_EFS=true
EFS_PERFORMANCE_MODE=generalPurpose
EFS_THROUGHPUT_MODE=elastic
```

Use the helper script to run Terraform with .env:

```bash
cd terraform
./tf-with-env.sh init
./tf-with-env.sh plan
./tf-with-env.sh apply
```

#### Option B: Using terraform.tfvars

Copy and edit the example file:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your configuration
```

Then run Terraform normally:

```bash
terraform init
terraform plan
terraform apply
```

### 2. Deploy ROSA HCP Cluster

```bash
# Deploy cluster (without domain validation)
make rosa-hcp-deploy

# Deploy cluster with domain validation
make rosa-hcp-deploy-with-domain

# Check deployment status
make rosa-hcp-output

# Get cluster credentials
make rosa-hcp-kubeconfig
```

### 3. Destroy Cluster

```bash
make rosa-hcp-destroy
```

## Terraform Configuration

The Terraform configuration is located in `terraform/` and includes:

- **rosa-hcp.tf**: Main ROSA HCP cluster configuration
- **network.tf**: VPC and subnet configuration
- **variables.tf**: All configurable variables
- **outputs.tf**: Cluster information outputs
- **provider.tf**: AWS and RHCS provider configuration

### Key Features

1. **Hosted Control Planes (HCP)**: Control plane runs in Red Hat's AWS account, reducing costs
2. **Automatic VPC Creation**: Creates VPC with public and private subnets
3. **IAM Role Management**: Automatically creates all required IAM roles
4. **OIDC Provider**: Sets up OIDC for secure authentication
5. **Flexible Configuration**: Supports custom domains, KMS encryption, and more

### Using Existing VPC

To use an existing VPC, set these environment variables:

```bash
ROSA_SUBNET_IDS=subnet-xxx,subnet-yyy,subnet-zzz
ROSA_AVAILABILITY_ZONES=us-east-1a,us-east-1b,us-east-1c
```

## Available Make Targets

| Target | Description |
|--------|-------------|
| `rosa-hcp-deploy` | Deploy ROSA HCP cluster |
| `rosa-hcp-destroy` | Destroy ROSA HCP cluster |
| `rosa-hcp-plan` | Preview Terraform changes |
| `rosa-hcp-output` | Show cluster information |
| `rosa-hcp-kubeconfig` | Configure kubectl/oc access |
| `rosa-terraform-init` | Initialize Terraform |
| `rosa-terraform-validate` | Validate Terraform configuration |
| `rosa-terraform-fmt` | Format Terraform files |

## Advanced Configuration

For detailed configuration options, see:
- [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example)
- [terraform/README-ROSA-HCP.md](terraform/README-ROSA-HCP.md)

## Architecture

ROSA with HCP provides:
- **Control plane** in Red Hat-managed AWS account
- **Worker nodes** in your AWS account
- **Cost optimization** through shared control plane
- **Faster provisioning** and automatic scaling
- **Enhanced reliability** with Red Hat managing critical components

## Troubleshooting

1. **Subnet Count Error**: Worker replicas must be a multiple of private subnet count (3)
2. **Domain Validation**: Ensure Route53 hosted zone exists before using custom domain
3. **IAM Permissions**: Verify AWS credentials have sufficient permissions

For more help, check the logs:
```bash
cd rosa/terraform
terraform show
```
