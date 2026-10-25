# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# Optional managed services. Every resource and data source in this file has
# count = 0 unless its deploy_* flag is true, so with all flags false (the
# default) nothing here is created or read.

locals {
  # Same major version as ROSA's RDS (15.x) and the repository's in-cluster
  # PostgresCluster (v15).
  postgres_version = "15"

  # The workers reach the internet, and the public endpoints of the
  # databases, through the zones' public gateways; their floating IPs are
  # the only sources the databases accept (allowlist).
  cluster_egress_ips = { for zone, fip in ibm_is_floating_ip.pgw : zone => fip.address }
}

###########################################
# IBM Cloud Databases for PostgreSQL
###########################################

# Smallest configuration: Classic "standard" plan (the Gen2 plans have no admin
# password, need a dedicated host and only offer private endpoints, which a
# VPC reaches only through a VPE gateway), shared host ("multitenant"), and the
# default (minimum) members, memory, disk and CPU. Public endpoint, limited to
# the cluster egress IPs.
resource "ibm_database" "postgres" {
  count = var.deploy_postgres ? 1 : 0

  name              = "${var.cluster_name}-postgres"
  service           = "databases-for-postgresql"
  plan              = "standard"
  location          = var.region
  resource_group_id = data.ibm_resource_group.group.id
  version           = local.postgres_version
  adminpassword     = var.postgres_admin_password
  service_endpoints = "public"
  tags              = local.tags

  # Ephemeral CI database: terraform destroy must delete it without manual
  # steps.
  deletion_protection = false

  group {
    group_id = "member"
    host_flavor {
      id = "multitenant"
    }
  }

  dynamic "allowlist" {
    for_each = local.cluster_egress_ips
    content {
      # IBM requires unique descriptions of at most 32 characters.
      address     = "${allowlist.value}/32"
      description = "cluster egress ${allowlist.key}"
    }
  }

  # Provisioning usually takes 30-45 minutes; the provider default (60m) is
  # tight, and a create timeout taints the instance.
  timeouts {
    create = "2h"
    update = "1h"
    delete = "1h"
  }
}

data "ibm_database_connection" "postgres" {
  count = var.deploy_postgres ? 1 : 0

  deployment_id = ibm_database.postgres[0].id
  user_type     = "database"
  user_id       = ibm_database.postgres[0].adminuser
  endpoint_type = "public"
}

###########################################
# IBM Cloud Databases for Redis
###########################################

# Provider rules for the admin password: 15-72 characters, at least one lower
# case letter, one upper case letter and one digit, no special characters
# other than - and _ (and not as the first character).
resource "random_password" "redis_admin" {
  count = var.deploy_redis ? 1 : 0

  length      = 32
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

# Same sizing and endpoint choices as PostgreSQL; version left to the IBM
# default (latest).
resource "ibm_database" "redis" {
  count = var.deploy_redis ? 1 : 0

  name              = "${var.cluster_name}-redis"
  service           = "databases-for-redis"
  plan              = "standard"
  location          = var.region
  resource_group_id = data.ibm_resource_group.group.id
  adminpassword     = random_password.redis_admin[0].result
  service_endpoints = "public"
  tags              = local.tags

  # Ephemeral CI database: terraform destroy must delete it without manual
  # steps.
  deletion_protection = false

  group {
    group_id = "member"
    host_flavor {
      id = "multitenant"
    }
  }

  dynamic "allowlist" {
    for_each = local.cluster_egress_ips
    content {
      # IBM requires unique descriptions of at most 32 characters.
      address     = "${allowlist.value}/32"
      description = "cluster egress ${allowlist.key}"
    }
  }

  timeouts {
    create = "2h"
    update = "1h"
    delete = "1h"
  }
}

data "ibm_database_connection" "redis" {
  count = var.deploy_redis ? 1 : 0

  deployment_id = ibm_database.redis[0].id
  user_type     = "database"
  user_id       = ibm_database.redis[0].adminuser
  endpoint_type = "public"
}
