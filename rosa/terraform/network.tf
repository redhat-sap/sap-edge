# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Kirill Satarin (@kksat)
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-FileContributor: Rishabh Bhandari (@RishabhKodes)

# SPDX-License-Identifier: Apache-2.0

locals {
  # Number of AZs to use, driven by the configured subnet lists.
  az_count = length(var.private_subnets)

  # Explicit zone-name allowlist derived from the region (e.g. eu-north-1a,
  # eu-north-1b, ...). CKV_AWS_394 only accepts an identity-based filter
  # (zone-name/zone-id) because it produces a closed, deterministic set that
  # cannot silently expand when AWS adds a new Availability Zone.
  availability_zone_names = [
    for i in range(local.az_count) :
    "${var.aws_region}${element(["a", "b", "c", "d", "e", "f"], i)}"
  ]
}

data "aws_availability_zones" "available" {
  state = "available"

  # Pin zone identity (CKV_AWS_394) to an explicit, closed set of AZ names.
  filter {
    name   = "zone-name"
    values = local.availability_zone_names
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  count                = 1
  name                 = var.vpc_name
  cidr                 = var.vpc_cidr
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = var.private_subnets
  public_subnets       = var.public_subnets
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = var.tags
}
