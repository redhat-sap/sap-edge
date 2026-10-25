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

###########################################
# Optional managed services (null when the deploy_* flag is false)
###########################################

output "postgres_host" {
  description = "Public hostname of the PostgreSQL instance (null unless deploy_postgres)"
  value       = var.deploy_postgres ? data.ibm_database_connection.postgres[0].postgres[0].hosts[0].hostname : null
}

output "postgres_port" {
  description = "Port of the PostgreSQL instance (null unless deploy_postgres)"
  value       = var.deploy_postgres ? data.ibm_database_connection.postgres[0].postgres[0].hosts[0].port : null
}

output "postgres_database" {
  description = "Database name for EIC, edgedb (null unless deploy_postgres). IBM Cloud Databases does not create it; see README.md"
  value       = var.deploy_postgres ? local.postgres_database : null
}

output "postgres_admin_username" {
  description = "Admin user of the PostgreSQL instance; its password is var.postgres_admin_password (null unless deploy_postgres)"
  value       = var.deploy_postgres ? ibm_database.postgres[0].adminuser : null
}

output "postgres_ca_certificate_base64" {
  description = "Base64-encoded CA certificate that signs the PostgreSQL TLS certificate (public, not a secret; null unless deploy_postgres or if IBM returns none)"
  value       = var.deploy_postgres ? try(data.ibm_database_connection.postgres[0].postgres[0].certificate[0].certificate_base64, null) : null
}

output "redis_host" {
  description = "Public hostname of the Redis instance, TLS only (null unless deploy_redis)"
  value       = var.deploy_redis ? data.ibm_database_connection.redis[0].rediss[0].hosts[0].hostname : null
}

output "redis_port" {
  description = "Port of the Redis instance (null unless deploy_redis)"
  value       = var.deploy_redis ? data.ibm_database_connection.redis[0].rediss[0].hosts[0].port : null
}

output "redis_username" {
  description = "Admin user of the Redis instance (Redis ACL user for AUTH <user> <password>; null unless deploy_redis)"
  value       = var.deploy_redis ? ibm_database.redis[0].adminuser : null
}

output "redis_password" {
  description = "Generated admin password of the Redis instance (null unless deploy_redis)"
  value       = var.deploy_redis ? random_password.redis_admin[0].result : null
  sensitive   = true
}

output "redis_ca_certificate_base64" {
  description = "Base64-encoded CA certificate that signs the Redis TLS certificate (public, not a secret; null unless deploy_redis or if IBM returns none)"
  value       = var.deploy_redis ? try(data.ibm_database_connection.redis[0].rediss[0].certificate[0].certificate_base64, null) : null
}

output "quay_cos_bucket" {
  description = "Name of the COS bucket for Quay (null unless deploy_quay_storage)"
  value       = var.deploy_quay_storage ? ibm_cos_bucket.quay[0].bucket_name : null
}

output "quay_cos_endpoint" {
  description = "Regional public S3 endpoint host of the Quay bucket, without scheme (e.g. s3.eu-de.cloud-object-storage.appdomain.cloud; null unless deploy_quay_storage)"
  value       = var.deploy_quay_storage ? ibm_cos_bucket.quay[0].s3_endpoint_public : null
}

output "quay_hmac_access_key_id" {
  description = "HMAC access key ID for the Quay bucket (null unless deploy_quay_storage)"
  value       = var.deploy_quay_storage ? ibm_resource_key.quay_hmac[0].credentials["cos_hmac_keys.access_key_id"] : null
  sensitive   = true
}

output "quay_hmac_secret_access_key" {
  description = "HMAC secret access key for the Quay bucket (null unless deploy_quay_storage)"
  value       = var.deploy_quay_storage ? ibm_resource_key.quay_hmac[0].credentials["cos_hmac_keys.secret_access_key"] : null
  sensitive   = true
}
