# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-License-Identifier: Apache-2.0

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
}

variable "environment_tag" {
  description = "Environment tag value"
  type        = string
  default     = "rosa"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_1_cidr" {
  description = "CIDR block for public subnet 1"
  type        = string
  default     = "10.0.0.0/24"
}

variable "public_subnet_2_cidr" {
  description = "CIDR block for public subnet 2"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_1_cidr" {
  description = "CIDR block for private subnet 1"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnet_2_cidr" {
  description = "CIDR block for private subnet 2"
  type        = string
  default     = "10.0.3.0/24"
}

variable "public_subnet_3_cidr" {
  description = "CIDR block for public subnet 3"
  type        = string
  default     = "10.0.4.0/24"
}

variable "private_subnet_3_cidr" {
  description = "CIDR block for private subnet 3"
  type        = string
  default     = "10.0.5.0/24"
}
