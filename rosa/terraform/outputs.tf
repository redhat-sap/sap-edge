# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Network Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnets" {
  description = "Comma-separated list of public subnet IDs"
  value       = "${aws_subnet.public_1.id},${aws_subnet.public_2.id},${aws_subnet.public_3.id}"
}

output "private_subnets" {
  description = "Comma-separated list of private subnet IDs"
  value       = "${aws_subnet.private_1.id},${aws_subnet.private_2.id},${aws_subnet.private_3.id}"
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [aws_subnet.public_1.id, aws_subnet.public_2.id, aws_subnet.public_3.id]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [aws_subnet.private_1.id, aws_subnet.private_2.id, aws_subnet.private_3.id]
}

output "all_subnet_ids" {
  description = "List of all subnet IDs"
  value = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id,
    aws_subnet.public_3.id,
    aws_subnet.private_1.id,
    aws_subnet.private_2.id,
    aws_subnet.private_3.id
  ]
}

output "availability_zones" {
  description = "List of availability zones used"
  value = [
    aws_subnet.public_1.availability_zone,
    aws_subnet.public_2.availability_zone,
    aws_subnet.public_3.availability_zone
  ]
}

# Domain Records Outputs (conditional)
output "api_endpoint" {
  description = "API endpoint DNS name"
  value       = var.domain_name != "" ? "api.${var.cluster_name}.${var.domain_name}" : ""
}

output "apps_wildcard" {
  description = "Apps wildcard DNS name"
  value       = var.domain_name != "" ? "*.apps.${var.cluster_name}.${var.domain_name}" : ""
}

output "console_endpoint" {
  description = "Console endpoint DNS name"
  value       = var.domain_name != "" ? "console-openshift-console.apps.${var.cluster_name}.${var.domain_name}" : ""
}

output "hosted_zone" {
  description = "Route53 hosted zone name"
  value       = var.domain_name
}

# ROSA HCP Cluster Outputs
output "cluster_id" {
  description = "Unique identifier of the ROSA HCP cluster"
  value       = try(module.rosa_hcp.cluster_id, "")
}

output "cluster_name" {
  description = "Name of the ROSA HCP cluster"
  value       = var.cluster_name
}

output "cluster_api_url" {
  description = "URL of the API server"
  value       = try(module.rosa_hcp.api_url, "")
}

output "cluster_console_url" {
  description = "URL of the console"
  value       = try(module.rosa_hcp.console_url, "")
}

output "cluster_domain" {
  description = "Domain of the cluster"
  value       = try(module.rosa_hcp.domain, "")
}

output "cluster_state" {
  description = "State of the cluster"
  value       = try(module.rosa_hcp.state, "")
}

output "cluster_version" {
  description = "OpenShift version of the cluster"
  value       = try(module.rosa_hcp.current_version, var.rosa_version)
}

output "oidc_endpoint_url" {
  description = "OIDC Endpoint URL"
  value       = try(module.rosa_hcp.oidc_endpoint_url, "")
}

output "oidc_config_id" {
  description = "OIDC Configuration ID"
  value       = try(module.rosa_hcp.oidc_config_id, "")
}

output "account_role_prefix" {
  description = "Prefix used for account IAM roles"
  value       = var.account_role_prefix != "" ? var.account_role_prefix : "${var.cluster_name}-account"
}

output "operator_role_prefix" {
  description = "Prefix used for operator IAM roles"
  value       = var.operator_role_prefix != "" ? var.operator_role_prefix : "${var.cluster_name}-operator"
}

output "admin_credentials" {
  description = "Admin credentials for the cluster (if created)"
  value = var.create_admin_user ? {
    username = var.admin_username
    password = var.admin_password != "" ? "(set via variable)" : "(auto-generated - check Terraform state)"
  } : null
  sensitive = true
}
