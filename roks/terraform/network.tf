# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

###########################################
# Shared values
###########################################

data "ibm_resource_group" "group" {
  name = var.resource_group
}

locals {
  # IBM resource tags are lowercase key:value strings.
  tags = concat(
    ["owner:redhat", "project:sap-edge"],
    var.pr_number == "" ? [] : ["pr:${var.pr_number}"],
  )

  # zone name => position in var.zones; per-zone resources are keyed by zone
  # name, the position picks the zone's address range.
  zones = { for index, zone in var.zones : zone => index }

  # Manual address prefixes inside 10.0.0.0/16: one /18 per zone
  # (10.0.0.0/18, 10.0.64.0/18, 10.0.128.0/18) and one /20 worker subnet at
  # the start of each prefix (10.0.0.0/20, 10.0.64.0/20, 10.0.128.0/20).
  vpc_cidr         = "10.0.0.0/16"
  address_prefixes = { for zone, index in local.zones : zone => cidrsubnet(local.vpc_cidr, 2, index) }
  subnet_cidrs     = { for zone, prefix in local.address_prefixes : zone => cidrsubnet(prefix, 2, 0) }
}

###########################################
# VPC
###########################################

resource "ibm_is_vpc" "vpc" {
  name                        = "${var.cluster_name}-vpc"
  resource_group              = data.ibm_resource_group.group.id
  address_prefix_management   = "manual"
  default_network_acl_name    = "${var.cluster_name}-default-acl"
  default_routing_table_name  = "${var.cluster_name}-default-rt"
  default_security_group_name = "${var.cluster_name}-default-sg"
  tags                        = local.tags
}

resource "ibm_is_vpc_address_prefix" "zone" {
  for_each = local.zones

  name = "${var.cluster_name}-prefix-${each.key}"
  vpc  = ibm_is_vpc.vpc.id
  zone = each.key
  cidr = local.address_prefixes[each.key]
}

###########################################
# Public gateways (worker egress) and subnets
###########################################

# Explicit floating IPs: one the gateway created implicitly would get a generated
# name and no tags, and the provider cannot pass it a resource group.
resource "ibm_is_floating_ip" "pgw" {
  for_each = local.zones

  name           = "${var.cluster_name}-pgw-fip-${each.key}"
  zone           = each.key
  resource_group = data.ibm_resource_group.group.id
  tags           = local.tags
}

resource "ibm_is_public_gateway" "zone" {
  for_each = local.zones

  name           = "${var.cluster_name}-pgw-${each.key}"
  vpc            = ibm_is_vpc.vpc.id
  zone           = each.key
  resource_group = data.ibm_resource_group.group.id
  tags           = local.tags

  floating_ip = {
    id = ibm_is_floating_ip.pgw[each.key].id
  }
}

resource "ibm_is_subnet" "zone" {
  for_each = local.zones

  name            = "${var.cluster_name}-subnet-${each.key}"
  vpc             = ibm_is_vpc.vpc.id
  zone            = each.key
  ipv4_cidr_block = local.subnet_cidrs[each.key]
  public_gateway  = ibm_is_public_gateway.zone[each.key].id
  resource_group  = data.ibm_resource_group.group.id
  tags            = local.tags

  # The subnet CIDR must sit inside an address prefix that already exists.
  depends_on = [ibm_is_vpc_address_prefix.zone]
}
