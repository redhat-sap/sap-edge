# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

###########################################
# Cluster
###########################################

variable "cluster_name" {
  description = "Name of the ROKS cluster, also the prefix of every other resource name (e.g. redhat-roks-eic-pr123). Must start with redhat-, max 32 characters."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 2-32 characters of lowercase letters, digits and hyphens, start with a letter and end with a letter or digit."
  }

  validation {
    condition     = startswith(var.cluster_name, "redhat-")
    error_message = "cluster_name must start with \"redhat-\" so that every IBM Cloud resource of the run is recognizable as Red Hat's (e.g. redhat-roks-eic-pr123)."
  }
}

variable "region" {
  description = "IBM Cloud region (VPC Gen2 multizone region)."
  type        = string
  default     = "eu-de"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+$", var.region))
    error_message = "region must be an IBM Cloud region name such as eu-de or us-south."
  }
}

variable "resource_group" {
  description = "Existing resource group that receives every resource (looked up, never created)."
  type        = string
  default     = "redhat-sap-edge-roks-ci"
}

variable "openshift_version" {
  description = "OpenShift version in ROKS format <major>.<minor>_openshift (see `ibmcloud oc versions`)."
  type        = string
  default     = "4.21_openshift"

  validation {
    condition     = can(regex("^4\\.[0-9]+_openshift$", var.openshift_version))
    error_message = "openshift_version must look like 4.21_openshift."
  }
}

variable "worker_flavor" {
  description = "VPC worker node flavor of the default worker pool (see `ibmcloud oc flavors --zone <zone>`)."
  type        = string
  default     = "bx2.16x64"

  validation {
    condition     = can(regex("^[a-z0-9]+\\.[a-z0-9.]+$", var.worker_flavor))
    error_message = "worker_flavor must be a VPC flavor name such as bx2.16x64."
  }
}

variable "workers_per_zone" {
  description = "Worker nodes per zone in the default worker pool (OpenShift needs at least 2 workers in total)."
  type        = number
  default     = 1

  validation {
    condition     = var.workers_per_zone >= 1 && floor(var.workers_per_zone) == var.workers_per_zone && var.workers_per_zone * length(var.zones) >= 2
    error_message = "workers_per_zone must be a whole number >= 1, and workers_per_zone x number of zones must be at least 2."
  }
}

variable "zones" {
  description = "Zones of the region for the worker subnets (one subnet, address prefix and public gateway per zone)."
  type        = list(string)
  default     = ["eu-de-1", "eu-de-2", "eu-de-3"]

  validation {
    condition     = length(var.zones) >= 1 && length(var.zones) <= 3 && length(distinct(var.zones)) == length(var.zones)
    error_message = "zones must list 1 to 3 distinct zones."
  }

  validation {
    condition     = alltrue([for zone in var.zones : can(regex("^${var.region}-[0-9]+$", zone))])
    error_message = "Every zone must belong to the selected region (e.g. eu-de-1 for region eu-de)."
  }
}

variable "pod_subnet" {
  description = "Pod network CIDR of the cluster. IBM only accepts /13 to /23 inside 172.17.0.0-172.17.255.255, 172.21.0.0-172.31.255.255, 192.168.0.0-192.168.254.255 or 198.18.0.0-198.19.255.255, not overlapping the default service subnet 172.21.0.0/16."
  type        = string
  default     = "172.17.0.0/18"

  validation {
    condition = try(
      cidrhost(var.pod_subnet, 0) == split("/", var.pod_subnet)[0] &&
      tonumber(split("/", var.pod_subnet)[1]) >= 13 &&
      tonumber(split("/", var.pod_subnet)[1]) <= 23,
      false
    )
    error_message = "pod_subnet must be a network CIDR (e.g. 172.17.0.0/18) with a prefix length between /13 and /23."
  }

  # IPv4 addresses are compared as integers: sum(octet * 256^(3 - position)).
  validation {
    condition = try(anytrue([
      for allowed in [
        ["172.17.0.0", "172.17.255.255"],
        ["172.21.0.0", "172.31.255.255"],
        ["192.168.0.0", "192.168.254.255"],
        ["198.18.0.0", "198.19.255.255"],
      ] :
      sum([for i, octet in split(".", cidrhost(var.pod_subnet, 0)) : tonumber(octet) * pow(256, 3 - i)]) >= sum([for i, octet in split(".", allowed[0]) : tonumber(octet) * pow(256, 3 - i)]) &&
      sum([for i, octet in split(".", cidrhost(var.pod_subnet, -1)) : tonumber(octet) * pow(256, 3 - i)]) <= sum([for i, octet in split(".", allowed[1]) : tonumber(octet) * pow(256, 3 - i)])
    ]), false)
    error_message = "pod_subnet must lie inside 172.17.0.0-172.17.255.255, 172.21.0.0-172.31.255.255, 192.168.0.0-192.168.254.255 or 198.18.0.0-198.19.255.255 (IBM Cloud restriction)."
  }

  validation {
    condition = try(
      sum([for i, octet in split(".", cidrhost(var.pod_subnet, -1)) : tonumber(octet) * pow(256, 3 - i)]) < sum([for i, octet in split(".", "172.21.0.0") : tonumber(octet) * pow(256, 3 - i)]) ||
      sum([for i, octet in split(".", cidrhost(var.pod_subnet, 0)) : tonumber(octet) * pow(256, 3 - i)]) > sum([for i, octet in split(".", "172.21.255.255") : tonumber(octet) * pow(256, 3 - i)]),
      false
    )
    error_message = "pod_subnet must not overlap the default ROKS service subnet 172.21.0.0/16."
  }
}

variable "pr_number" {
  description = "Pull request number of the run; adds the tag pr:<N> when set."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[0-9]*$", var.pr_number))
    error_message = "pr_number must be empty or digits only."
  }
}

variable "kubeconfig_dir" {
  description = "Existing directory where the admin kubeconfig is downloaded (the IBM provider fails if it does not exist). The default ./.kube is committed (roks/terraform/.kube/.gitkeep); its contents are git-ignored."
  type        = string
  default     = "./.kube"

  validation {
    condition     = trimspace(var.kubeconfig_dir) != ""
    error_message = "kubeconfig_dir must not be empty."
  }
}

###########################################
# Optional managed services
###########################################

# tflint-ignore: terraform_unused_declarations # consumed by the optional services (services.tf)
variable "deploy_postgres" {
  description = "Create an IBM Cloud Databases for PostgreSQL instance."
  type        = bool
  default     = false
}

# tflint-ignore: terraform_unused_declarations # consumed by the optional services (services.tf)
variable "deploy_redis" {
  description = "Create an IBM Cloud Databases for Redis instance."
  type        = bool
  default     = false
}

# tflint-ignore: terraform_unused_declarations # consumed by the optional services (services.tf)
variable "deploy_quay_storage" {
  description = "Create a COS bucket and HMAC credentials for Quay registry storage."
  type        = bool
  default     = false
}

# tflint-ignore: terraform_unused_declarations # consumed by the optional services (services.tf)
variable "postgres_admin_password" {
  description = "Admin password of the PostgreSQL instance (only used when deploy_postgres is true)."
  type        = string
  sensitive   = true
  default     = ""
}
