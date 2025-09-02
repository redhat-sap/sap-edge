# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Data source to get availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  vpc_name = var.create_vpc ? "rosa-${var.cluster_name}-vpc" : var.vpc_name
}

# VPC
resource "aws_vpc" "main" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = local.vpc_name
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = {
    Name = "${local.vpc_name}-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public_1" {
  count                   = var.create_vpc ? 1 : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_1_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.vpc_name}-public-1"
    "kubernetes.io/role/elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "public_2" {
  count                   = var.create_vpc ? 1 : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_2_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.vpc_name}-public-2"
    "kubernetes.io/role/elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

# Private Subnets
resource "aws_subnet" "private_1" {
  count             = var.create_vpc ? 1 : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.private_subnet_1_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name                              = "${local.vpc_name}-private-1"
    "kubernetes.io/role/internal-elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "private_2" {
  count             = var.create_vpc ? 1 : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.private_subnet_2_cidr
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name                              = "${local.vpc_name}-private-2"
    "kubernetes.io/role/internal-elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "public_3" {
  count                   = var.create_vpc ? 1 : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_3_cidr
  availability_zone       = data.aws_availability_zones.available.names[2]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.vpc_name}-public-3"
    "kubernetes.io/role/elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "private_3" {
  count             = var.create_vpc ? 1 : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.private_subnet_3_cidr
  availability_zone = data.aws_availability_zones.available.names[2]

  tags = {
    Name                              = "${local.vpc_name}-private-3"
    "kubernetes.io/role/internal-elb" = "1"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

# Elastic IPs for NAT Gateways
resource "aws_eip" "nat_1" {
  count      = var.create_vpc ? 1 : 0
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.vpc_name}-nat-eip-1"
  }
}

resource "aws_eip" "nat_2" {
  count      = var.create_vpc ? 1 : 0
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.vpc_name}-nat-eip-2"
  }
}

resource "aws_eip" "nat_3" {
  count      = var.create_vpc ? 1 : 0
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.vpc_name}-nat-eip-3"
  }
}

# NAT Gateways
resource "aws_nat_gateway" "nat_1" {
  count         = var.create_vpc ? 1 : 0
  allocation_id = aws_eip.nat_1[0].id
  subnet_id     = aws_subnet.public_1[0].id

  tags = {
    Name = "${local.vpc_name}-nat-1"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_2" {
  count         = var.create_vpc ? 1 : 0
  allocation_id = aws_eip.nat_2[0].id
  subnet_id     = aws_subnet.public_2[0].id

  tags = {
    Name = "${local.vpc_name}-nat-2"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_3" {
  count         = var.create_vpc ? 1 : 0
  allocation_id = aws_eip.nat_3[0].id
  subnet_id     = aws_subnet.public_3[0].id

  tags = {
    Name = "${local.vpc_name}-nat-3"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route Tables
resource "aws_route_table" "public" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = {
    Name = "${local.vpc_name}-public-rt"
  }
}

resource "aws_route_table" "private_1" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_1[0].id
  }

  tags = {
    Name = "${local.vpc_name}-private-rt-1"
  }
}

resource "aws_route_table" "private_2" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2[0].id
  }

  tags = {
    Name = "${local.vpc_name}-private-rt-2"
  }
}

resource "aws_route_table" "private_3" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_3[0].id
  }

  tags = {
    Name = "${local.vpc_name}-private-rt-3"
  }
}

# Route Table Associations
resource "aws_route_table_association" "public_1" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.public_1[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "public_2" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.public_2[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private_1" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.private_1[0].id
  route_table_id = aws_route_table.private_1[0].id
}

resource "aws_route_table_association" "private_2" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.private_2[0].id
  route_table_id = aws_route_table.private_2[0].id
}

resource "aws_route_table_association" "public_3" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.public_3[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private_3" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.private_3[0].id
  route_table_id = aws_route_table.private_3[0].id
}
