# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

output "cluster_id" {
  description = "ID of the ROKS cluster"
  value       = ibm_container_vpc_cluster.cluster.id
}

output "cluster_name" {
  description = "Name of the ROKS cluster"
  value       = ibm_container_vpc_cluster.cluster.name
}

output "ingress_hostname" {
  description = "Ingress subdomain of the cluster (e.g. <name>-<hash>-0000.eu-de.containers.appdomain.cloud)"
  value       = ibm_container_vpc_cluster.cluster.ingress_hostname
}

output "resource_group_id" {
  description = "ID of the resource group that holds every resource"
  value       = data.ibm_resource_group.group.id
}

output "admin_kubeconfig_path" {
  description = "Local path of the downloaded admin kubeconfig (may reference files in its directory; use `oc config view --flatten` before copying it elsewhere)"
  value       = data.ibm_container_cluster_config.admin.config_file_path
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = ibm_is_vpc.vpc.id
}
