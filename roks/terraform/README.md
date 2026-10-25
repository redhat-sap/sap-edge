<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# ROKS Terraform

Terraform for a Red Hat OpenShift on IBM Cloud (ROKS) cluster on VPC Gen2,
used by the ROKS EIC validation pipeline (one cluster per pull request) and
for local use through `roks.makefile`. Provider:
[`IBM-Cloud/ibm`](https://registry.terraform.io/providers/IBM-Cloud/ibm/latest/docs)
`~> 2.8.0`, Terraform `>= 1.10`.

## What it creates

All resources go into the existing resource group `redhat-sap-edge-roks-ci`
(looked up with a data source, never created). Nothing is created outside it.

| Resource | Name |
|---|---|
| VPC (manual address prefixes) and its default ACL, security group, routing table | `<cluster_name>-vpc`, `<cluster_name>-default-acl`/`-default-sg`/`-default-rt` |
| One address prefix per zone | `<cluster_name>-prefix-<zone>` |
| One public gateway per zone (worker egress) and its floating IP | `<cluster_name>-pgw-<zone>`, `<cluster_name>-pgw-fip-<zone>` |
| One worker subnet per zone, attached to the zone's public gateway | `<cluster_name>-subnet-<zone>` |
| Cloud Object Storage instance (standard, global; ROKS on VPC needs it for the internal registry) | `<cluster_name>-cos` |
| ROKS cluster: `bx2.16x64`, 1 worker per zone across 3 zones, no entitlement (regular OpenShift license), public service endpoint on, outbound traffic protection off | `<cluster_name>` |
| `terraform_data.vpe_cleanup`: destroy-time hook that deletes the VPE gateways ROKS leaves in the VPC (see [Destroy](#destroy)) | - |

`cluster_name` must start with `redhat-` (the pipeline uses
`redhat-roks-eic-pr<N>`), so every resource name starts with `redhat-`. Every
resource that supports tags gets `owner:redhat`, `project:sap-edge` and, when
`pr_number` is set, `pr:<N>`.

Cluster settings worth knowing:

- `disable_outbound_traffic_protection = true`: OpenShift 4.15+ on VPC blocks
  public egress from workers by default; the cluster needs it for
  OperatorHub, `registry.redhat.io`, SAP registries and ELM.
- `force_delete_storage = true`: volumes created by PVCs are deleted with the
  cluster, so no billable storage stays behind.
- `wait_till = "IngressReady"` with a 3 h create timeout.

## Network ranges and the httpbinipfilter allowlist

| Range | Use |
|---|---|
| `10.0.0.0/16` | VPC: address prefixes `10.0.0.0/18`, `10.0.64.0/18`, `10.0.128.0/18`; worker subnets `10.0.0.0/20`, `10.0.64.0/20`, `10.0.128.0/20` |
| `172.17.0.0/18` | Pod network (`pod_subnet`, the ROKS default) |
| `172.21.0.0/16` | Service network (ROKS default, not set here) |

IBM only accepts a pod subnet of `/13` to `/23` inside `172.17.0.0-172.17.255.255`,
`172.21.0.0-172.31.255.255`, `192.168.0.0-192.168.254.255` or
`198.18.0.0-198.19.255.255` (and it must not overlap the service subnet), so
the OpenShift default `10.128.0.0/14` used on ROSA/ARO is not possible; the
`pod_subnet` variable validates this.

**One-time step:** the SAP `httpbinipfilter` iFlow has an IP filter; add
`172.17.0.0/18` (pod network) and `10.0.0.0/16` (VPC) to its allowlist once.

## One-time setup

1. Resource group `redhat-sap-edge-roks-ci` (exists).
2. A service ID (e.g. `redhat-sap-edge-roks-ci`) with an API key and access to
   VPC Infrastructure Services, Kubernetes Service, Cloud Object Storage and
   Databases in that resource group. Export the key as `IBMCLOUD_API_KEY`.
3. A COS bucket for the Terraform state and HMAC credentials for it
   (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). The state holds the cluster
   admin certificate and the ingress secret: keep the bucket private.

## Terraform state (COS through the s3 backend)

`provider.tf` declares an empty `backend "s3" {}`; the settings are passed at
`terraform init`. One state per cluster, key `roks/<cluster_name>/terraform.tfstate`.

As a file (what `make roks/terraform/backend.config` writes):

```hcl
bucket                      = "<state bucket>"
key                         = "roks/<cluster_name>/terraform.tfstate"
region                      = "eu-de"
endpoints                   = { s3 = "https://s3.eu-de.cloud-object-storage.appdomain.cloud" }
use_lockfile                = true
use_path_style              = true
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_s3_checksum            = true
```

Or as flags:

```bash
terraform init -input=false \
  -backend-config="bucket=<state bucket>" \
  -backend-config="key=roks/<cluster_name>/terraform.tfstate" \
  -backend-config="region=eu-de" \
  -backend-config='endpoints={s3="https://s3.eu-de.cloud-object-storage.appdomain.cloud"}' \
  -backend-config="use_lockfile=true" \
  -backend-config="use_path_style=true" \
  -backend-config="skip_credentials_validation=true" \
  -backend-config="skip_region_validation=true" \
  -backend-config="skip_requesting_account_id=true" \
  -backend-config="skip_s3_checksum=true"
```

`use_lockfile` writes a `.tflock` object next to the state. If COS does not
enforce conditional writes the lock is best effort; each cluster has its own
key and the pipeline serializes runs per PR.

## Usage (from the repository root)

```bash
export IBMCLOUD_API_KEY=...            # IBM Cloud API key
export AWS_ACCESS_KEY_ID=...           # COS HMAC key of the state bucket
export AWS_SECRET_ACCESS_KEY=...
export TERRAFORM_STATE_BUCKET=<state bucket>
# optional: TERRAFORM_STATE_ENDPOINT (default: eu-de public COS endpoint)

make roks-init    CLUSTER=redhat-roks-eic-pr123
make roks-plan    CLUSTER=redhat-roks-eic-pr123 ROKS_TF_ARGS="-var pr_number=123"
make roks-apply   CLUSTER=redhat-roks-eic-pr123 ROKS_TF_ARGS="-var pr_number=123"
make roks-destroy CLUSTER=redhat-roks-eic-pr123
```

Other variables go into `roks/terraform/terraform.tfvars` (see
`terraform.tfvars.example`) or `ROKS_TF_ARGS`.

### Destroy

`make roks-destroy` runs `terraform destroy -refresh=false`. It is the manual
cleanup path for runs that failed or were rejected (those keep the cluster for
debugging). Without `-refresh=false`, Terraform re-reads the admin-kubeconfig
data source first, which fails when the cluster is already (half) gone or the
kubeconfig directory is missing.

**Requirements for destroy** (`terraform destroy` and `make roks-destroy`):
`bash`, `jq` and the `ibmcloud` CLI with the `vpc-infrastructure` plugin
(`ibmcloud plugin install vpc-infrastructure`), logged in to the account
(`ibmcloud login --apikey "$IBMCLOUD_API_KEY" -r eu-de`).

**VPE cleanup hook:** when the first cluster is created in a VPC, ROKS creates
shared VPC endpoint gateways named `iks-*` (Container Registry, COS, cluster
service API, VPC API) and the security group `kube-vpegw-<vpc_id>`. ROKS does
not delete them when the cluster goes, and the VPC cannot be deleted while
they exist. `terraform_data.vpe_cleanup` (in `cluster.tf`) has a destroy-time
`local-exec` provisioner that runs `scripts/delete-vpe-gateways.sh <vpc_id> <region>`:
it deletes only the `iks-*` endpoint gateways of this VPC, waits up to 15
minutes until they are gone, then deletes `kube-vpegw-<vpc_id>`. The cluster
depends on the hook and the hook on the VPC and subnets, so on destroy it runs
after the cluster is deleted and before the subnets and the VPC. If it fails,
destroy stops with the hook, subnets and VPC still in the state; rerun the
destroy.

### Admin kubeconfig

`data "ibm_container_cluster_config" "admin"` downloads the admin kubeconfig
into `kubeconfig_dir` (default `./.kube`, i.e. `roks/terraform/.kube/`); the
output `admin_kubeconfig_path` is the file. The IBM provider fails if the
directory does not exist, which is why `roks/terraform/.kube/.gitkeep` is
committed; everything else in it is git-ignored. The file may point to
certificate files in its directory, so use
`oc config view --kubeconfig "$(terraform output -raw admin_kubeconfig_path)" --flatten --raw`
before you copy it elsewhere. It grants cluster-admin: do not share it.

## Inputs

| Name | Default | Description |
|---|---|---|
| `cluster_name` | (required) | Cluster name and name prefix; `^[a-z][a-z0-9-]{0,30}[a-z0-9]$`, starts with `redhat-` |
| `region` | `eu-de` | IBM Cloud region |
| `resource_group` | `redhat-sap-edge-roks-ci` | Existing resource group |
| `openshift_version` | `4.21_openshift` | `<major>.<minor>_openshift` |
| `worker_flavor` | `bx2.16x64` | Worker flavor |
| `workers_per_zone` | `1` | Workers per zone (at least 2 in total) |
| `zones` | `["eu-de-1","eu-de-2","eu-de-3"]` | 1-3 zones of `region` |
| `pod_subnet` | `172.17.0.0/18` | Pod network (IBM-allowed ranges only, see above) |
| `pr_number` | `""` | Adds tag `pr:<N>` |
| `kubeconfig_dir` | `./.kube` | Existing directory for the admin kubeconfig |
| `deploy_postgres` | `false` | Optional IBM Cloud Databases for PostgreSQL |
| `deploy_redis` | `false` | Optional IBM Cloud Databases for Redis |
| `deploy_quay_storage` | `false` | Optional COS bucket and HMAC key for Quay |
| `postgres_admin_password` | `""` (sensitive) | PostgreSQL admin password |

## Outputs

| Name | Description |
|---|---|
| `cluster_id` | Cluster ID |
| `cluster_name` | Cluster name |
| `ingress_hostname` | Ingress subdomain (`*.eu-de.containers.appdomain.cloud`) |
| `resource_group_id` | Resource group ID |
| `admin_kubeconfig_path` | Path of the downloaded admin kubeconfig |
| `vpc_id` | VPC ID |

## Lint

`make lint` runs `roks-tflint`, `roks-tfsec` and `roks-checkov` with the rest of
the repository linters. Locally, without cloud access:

```bash
terraform -chdir=roks/terraform init -backend=false
terraform -chdir=roks/terraform validate
terraform fmt -check -recursive roks/terraform
make roks-tflint roks-tfsec roks-checkov
```
