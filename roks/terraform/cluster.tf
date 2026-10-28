# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

###########################################
# Cloud Object Storage (internal registry backup, required by ROKS on VPC)
###########################################

resource "ibm_resource_instance" "cos" {
  name              = "${var.cluster_name}-cos"
  service           = "cloud-object-storage"
  plan              = "standard"
  location          = "global"
  resource_group_id = data.ibm_resource_group.group.id
  tags              = local.tags
}

###########################################
# VPE cleanup on destroy
###########################################

# The first cluster in a VPC makes ROKS create shared VPE gateways (iks-*) and
# the security group kube-vpegw-<vpc_id>; ROKS never deletes them, and they
# block deleting the subnets and the VPC. Destroy order is the reverse of the
# dependencies: the cluster depends on this resource, which depends on the VPC
# and the subnets, so on destroy the hook runs after the cluster is gone and
# before the subnets and the VPC are deleted. Needs a logged-in ibmcloud CLI
# with the vpc-infrastructure plugin and jq.
resource "terraform_data" "vpe_cleanup" {
  input = {
    vpc_id = ibm_is_vpc.vpc.id
    region = var.region
  }

  provisioner "local-exec" {
    when        = destroy
    working_dir = path.module
    command     = "bash scripts/delete-vpe-gateways.sh \"$VPC_ID\" \"$REGION\""
    environment = {
      VPC_ID = self.input.vpc_id
      REGION = self.input.region
    }
  }

  depends_on = [ibm_is_subnet.zone]
}

###########################################
# ROKS cluster
###########################################

resource "ibm_container_vpc_cluster" "cluster" {
  name              = var.cluster_name
  vpc_id            = ibm_is_vpc.vpc.id
  resource_group_id = data.ibm_resource_group.group.id
  kube_version      = var.openshift_version
  flavor            = var.worker_flavor
  worker_count      = var.workers_per_zone
  cos_instance_crn  = ibm_resource_instance.cos.crn
  pod_subnet        = var.pod_subnet
  # entitlement stays unset: regular OpenShift license, no Cloud Pak.

  # The hub reaches the cluster API over the internet.
  disable_public_service_endpoint = false

  # Workers need internet egress through the public gateways (OperatorHub,
  # registry.redhat.io, SAP registries, ELM); 4.15+ blocks it by default.
  disable_outbound_traffic_protection = true

  # Ephemeral CI cluster: ask ROKS to delete the volumes created by PVCs together
  # with the cluster. VPC Block Storage volumes can still remain (even with a
  # Delete storage class); the roks-teardown task sweeps leftover volumes.
  force_delete_storage = true

  wait_till = "IngressReady"
  tags      = local.tags

  dynamic "zones" {
    for_each = local.zones
    content {
      name      = zones.key
      subnet_id = ibm_is_subnet.zone[zones.key].id
    }
  }

  # A multizone OpenShift cluster usually takes 60-90 minutes to reach
  # IngressReady; the provider defaults (90m create, 45m delete) are too tight,
  # and a create timeout taints the cluster (the next apply would replace it).
  timeouts {
    create = "3h"
    update = "2h"
    delete = "2h"
  }

  # Destroyed before the VPE cleanup hook runs (see terraform_data.vpe_cleanup).
  depends_on = [terraform_data.vpe_cleanup]

  # The version only selects what a new cluster is created with; IBM (patch
  # updates) or an admin (minor updates) can move the master later, and
  # applying an older version would try a downgrade, which IBM rejects (E0144).
  lifecycle {
    ignore_changes = [kube_version]
  }
}

# ReadWriteMany storage for EIC: the IBM Cloud File Storage for VPC CSI driver
# add-on provides the ibmc-vpc-file-* storage classes (ROKS VPC only ships the
# block classes). Enabled with the ibmcloud CLI in its default version, only if
# it is not enabled yet; the other add-ons are left alone. Not
# ibm_container_addons: it fails on an add-on that is already enabled unless
# the version is pinned, and with its default manage_all_addons = true a later
# apply disables every add-on it does not list.
resource "terraform_data" "file_storage_addon" {
  triggers_replace = [ibm_container_vpc_cluster.cluster.id]

  provisioner "local-exec" {
    working_dir = path.module
    command     = "bash scripts/enable-cluster-addon.sh \"$CLUSTER\" vpc-file-csi-driver"
    environment = {
      CLUSTER = ibm_container_vpc_cluster.cluster.id
    }
  }
}

###########################################
# Admin kubeconfig
###########################################

# Downloads the admin kubeconfig (client certificate) into var.kubeconfig_dir,
# which must exist. Destroy with -refresh=false so that this data source is not
# re-read (it needs the cluster API and the directory).
data "ibm_container_cluster_config" "admin" {
  cluster_name_id   = ibm_container_vpc_cluster.cluster.id
  resource_group_id = data.ibm_resource_group.group.id
  admin             = true
  config_dir        = var.kubeconfig_dir
}
