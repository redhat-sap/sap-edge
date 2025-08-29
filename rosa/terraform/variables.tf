# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
}

variable "cluster_name" {
  description = "Name of the ROSA cluster"
  type        = string
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "environment_tag" {
  description = "Environment tag value"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "public_subnet_1_cidr" {
  description = "CIDR block for public subnet 1"
  type        = string
}

variable "public_subnet_2_cidr" {
  description = "CIDR block for public subnet 2"
  type        = string
}

variable "private_subnet_1_cidr" {
  description = "CIDR block for private subnet 1"
  type        = string
}

variable "private_subnet_2_cidr" {
  description = "CIDR block for private subnet 2"
  type        = string
}

variable "public_subnet_3_cidr" {
  description = "CIDR block for public subnet 3"
  type        = string
}

variable "private_subnet_3_cidr" {
  description = "CIDR block for private subnet 3"
  type        = string
}
