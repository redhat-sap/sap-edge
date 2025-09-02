# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Data source to get cluster details
data "rhcs_cluster_rosa_hcp" "cluster" {
  id = module.rosa_hcp.cluster_id
}

# Domain Records Outputs (conditional)
output "api_endpoint" {
  description = "API endpoint URL"
  value       = data.rhcs_cluster_rosa_hcp.cluster.api_url
}

output "console_endpoint" {
  description = "Console endpoint URL"
  value       = data.rhcs_cluster_rosa_hcp.cluster.console_url
}

output "cluster_name" {
  description = "Name of the ROSA HCP cluster"
  value       = var.cluster_name
}

output "admin_credentials" {
  description = "Admin credentials for the cluster (if created)"
  value = var.create_admin_user ? {
    username = var.admin_username
    password = var.admin_password != "" ? var.admin_password : "(use 'rosa create admin' command to generate)"
  } : null
  sensitive = true
}

output "domain_name" {
  description = "The domain name configured for Route53 records"
  value       = var.domain_name
}
