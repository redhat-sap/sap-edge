# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

# IBM Cloud Container Registry (ICR) for the EIC validation: a namespace named
# after the cluster, and a service ID whose API key can push and pull in that
# namespace only (entered in ELM as the container registry). Always created.

locals {
  # Regional registry host per IBM Cloud region (the provider creates the
  # namespace in the registry of the provider region).
  icr_registries = {
    "au-syd"   = "au.icr.io"
    "br-sao"   = "br.icr.io"
    "ca-mon"   = "ca2.icr.io"
    "ca-tor"   = "ca.icr.io"
    "eu-de"    = "de.icr.io"
    "eu-es"    = "es.icr.io"
    "eu-gb"    = "uk.icr.io"
    "jp-osa"   = "jp2.icr.io"
    "jp-tok"   = "jp.icr.io"
    "us-south" = "us.icr.io"
  }
  icr_registry = lookup(local.icr_registries, var.region, "")
}

# Namespace names are unique per registry region across all IBM Cloud accounts
# (4-30 characters). Deleting the namespace deletes its images, trash and trust
# data. The provider keeps namespace tags only in the Terraform state, so none
# are set.
resource "ibm_cr_namespace" "icr" {
  name              = var.cluster_name
  resource_group_id = data.ibm_resource_group.group.id

  lifecycle {
    precondition {
      condition     = local.icr_registry != ""
      error_message = "region ${var.region} has no IBM Cloud Container Registry mapping in registry.tf (icr_registries)."
    }
  }
}

# Account-level identity (service IDs have no resource group); deleted with the
# run's other resources by terraform destroy.
resource "ibm_iam_service_id" "icr" {
  name        = "${var.cluster_name}-icr"
  description = "Red Hat SAP Edge ROKS CI run ${var.cluster_name}: push and pull images in ICR namespace ${var.cluster_name} (${local.icr_registry})."
}

# Reader (pull) and Writer (push) on this one namespace in this one region,
# nothing broader.
resource "ibm_iam_service_policy" "icr" {
  iam_id      = ibm_iam_service_id.icr.iam_id
  roles       = ["Reader", "Writer"]
  description = "Red Hat SAP Edge ROKS CI run ${var.cluster_name}: ICR namespace ${ibm_cr_namespace.icr.name} only."

  resources {
    service       = "container-registry"
    region        = var.region
    resource_type = "namespace"
    resource      = ibm_cr_namespace.icr.name
  }
}

# The key value is only returned at creation and kept in the Terraform state
# (store_value unset: IBM does not keep a retrievable copy).
resource "ibm_iam_service_api_key" "icr" {
  name           = "${var.cluster_name}-icr"
  iam_service_id = ibm_iam_service_id.icr.iam_id
  description    = "Registry login (user iamapikey) for ICR namespace ${var.cluster_name}."
}
