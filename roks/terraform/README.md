<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# ROKS Terraform

Terraform for a Red Hat OpenShift on IBM Cloud (ROKS) cluster on VPC Gen2,
used by the ROKS EIC validation pipeline (one cluster per pull request) and
for local use through `roks.makefile`. Providers:
[`IBM-Cloud/ibm`](https://registry.terraform.io/providers/IBM-Cloud/ibm/latest/docs)
`~> 2.8.0` and `hashicorp/random` `~> 3.9.0` (Redis password), Terraform `>= 1.10`.

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
| Optional, `deploy_postgres`: IBM Cloud Databases for PostgreSQL 15 (see [Optional managed services](#optional-managed-services)) | `<cluster_name>-postgres` |
| Optional, `deploy_redis`: IBM Cloud Databases for Redis | `<cluster_name>-redis` |
| Optional, `deploy_quay_storage`: COS bucket in the cluster's COS instance, and an HMAC key for it | `<cluster_name>-quay`, `<cluster_name>-quay-hmac` |

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

## Optional managed services

`services.tf` holds the services that mirror ROSA's `deployPostgres`,
`deployRedis` and `deployQuay`. Each resource and data source in it has
`count = 0` unless its flag is `true`, so with the default (all `false`)
nothing is created, and every output below is `null`.

**Databases** (`deploy_postgres`, `deploy_redis`), in `region` (`eu-de`):

- Smallest configuration: the Classic `standard` plan on a shared host
  (`host_flavor` `multitenant`), with IBM's default (minimum) members, memory,
  disk and CPU. The Gen2 plans (`standard-gen2`) are not used: they have no
  admin password, need a dedicated host flavor, and only offer private
  endpoints, which a VPC reaches only through a VPE gateway.
- Public endpoints, TLS only. Each database's allowlist holds the floating IPs
  of the cluster's public gateways (the workers' egress), so only the cluster
  can connect. To connect from elsewhere (e.g. a laptop for debugging), add
  your IP (the next `terraform apply` removes it again):
  `ibmcloud cdb deployment-allowlist-add <cluster_name>-postgres <ip>/32 debug`.
- PostgreSQL 15, as on ROSA (RDS 15.x) and in the repository's in-cluster
  PostgresCluster (v15). The admin user
  is `admin` (output `postgres_admin_username`) with password
  `postgres_admin_password`, which must be 15-32 characters with at least one
  letter and one digit, and no special characters other than `-` and `_`
  (IBM's rule; the variable is validated).
- **`edgedb` is not created by Terraform.** IBM Cloud Databases creates only
  the database `ibmclouddb`, and the provider cannot create others. Output
  `postgres_database` is the name EIC is given (`edgedb`); create it before EIC
  uses it, e.g. from a pod in the cluster (the allowlist admits the cluster):
  `psql "host=<postgres_host> port=<postgres_port> dbname=ibmclouddb user=admin sslmode=require" -c 'CREATE DATABASE edgedb'`.
- Redis: IBM's default version, admin user `admin` (output `redis_username`),
  32-character generated password (sensitive output `redis_password`). Clients
  must use TLS.
- IBM signs the database certificates with its own CA. Outputs
  `postgres_ca_certificate_base64` and `redis_ca_certificate_base64` hold it
  for clients that verify the certificate (`sslmode=verify-full`, Redis TLS).
- Provisioning takes 30-45 minutes (create timeout 2 h). The databases do not
  depend on the cluster, so Terraform creates them in parallel with it.
- Destroy: `deletion_protection = false`, so `terraform destroy` deletes them
  without manual steps. IBM then keeps a deleted instance in pending
  reclamation for a service-specific period (typically a few days), during
  which it can be restored. To purge it at once, find the reclamation ID with
  `ibmcloud resource reclamations` and run
  `ibmcloud resource reclamation-delete <reclamation ID>`.

**Quay storage** (`deploy_quay_storage`):

- A regional `standard` bucket `<cluster_name>-quay` in `region`, in the
  cluster's COS instance (`<cluster_name>-cos`). Output `quay_cos_endpoint` is
  the bucket's regional public S3 endpoint host without a scheme
  (`s3.eu-de.cloud-object-storage.appdomain.cloud`), reached from the cluster
  through the public gateways.
- An HMAC resource key `<cluster_name>-quay-hmac` with the Writer role (the
  least role that can read, write and delete objects). The role covers every
  bucket of the COS instance, including the one ROKS creates for the internal
  registry.
- `force_delete = true`: destroy empties the bucket before deleting it. Bucket
  names are global across IBM Cloud, and IBM may hold a deleted bucket's name
  for a while before it can be reused.
- COS buckets and resource keys cannot carry tags.

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
   For `deploy_quay_storage` it also needs at least the Writer service role on
   Cloud Object Storage (to issue a Writer HMAC key); IBM creates a service ID
   for the key, so if the account restricts service ID creation it also needs
   the Service ID creator role.
3. A COS bucket for the Terraform state and HMAC credentials for it
   (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). The state holds the cluster
   admin certificate, the ingress secret and, when the optional services are
   on, the database passwords and the Quay HMAC key: keep the bucket private.

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
| `postgres_admin_password` | `""` (sensitive) | PostgreSQL admin password; required when `deploy_postgres`, 15-32 characters of letters, digits, `-`, `_` with at least one letter and one digit |

## Outputs

| Name | Description |
|---|---|
| `cluster_id` | Cluster ID |
| `cluster_name` | Cluster name |
| `ingress_hostname` | Ingress subdomain (`*.eu-de.containers.appdomain.cloud`) |
| `resource_group_id` | Resource group ID |
| `admin_kubeconfig_path` | Path of the downloaded admin kubeconfig |
| `vpc_id` | VPC ID |
| `postgres_host`, `postgres_port` | PostgreSQL public hostname and port |
| `postgres_database` | `edgedb` (created after provisioning, see above) |
| `postgres_admin_username` | `admin` |
| `postgres_ca_certificate_base64` | CA certificate of the PostgreSQL TLS certificate (not a secret) |
| `redis_host`, `redis_port` | Redis public hostname and port (TLS) |
| `redis_username` | `admin` |
| `redis_password` | Generated Redis admin password (sensitive) |
| `redis_ca_certificate_base64` | CA certificate of the Redis TLS certificate (not a secret) |
| `quay_cos_bucket` | Quay bucket name |
| `quay_cos_endpoint` | Regional public S3 endpoint host of the bucket |
| `quay_hmac_access_key_id`, `quay_hmac_secret_access_key` | HMAC credentials for the bucket (sensitive) |

The service outputs are `null` when their flag is `false`. Read sensitive
outputs with `terraform output -raw <name>`, and do not print them in logs.

## Validate

Offline checks, without cloud access or credentials. `terraform validate`
checks every resource, including the ones that the `deploy_*` flags switch off,
but it does not read variable values. The loop checks that every output the
pipeline tasks read is declared:

```bash
terraform -chdir=roks/terraform init -backend=false
terraform -chdir=roks/terraform validate
for output in postgres_host postgres_port postgres_database \
  redis_host redis_port redis_password \
  quay_cos_bucket quay_cos_endpoint \
  quay_hmac_access_key_id quay_hmac_secret_access_key; do
  grep -q "^output \"${output}\"" roks/terraform/outputs.tf ||
    echo "missing output: ${output}"
done
```

A plan with the flags turned on needs credentials:
`make roks-plan CLUSTER=<name> ROKS_TF_ARGS="-var deploy_postgres=true -var deploy_redis=true -var deploy_quay_storage=true"`
(with `TF_VAR_postgres_admin_password` exported).

## Lint

`make lint` runs `roks-tflint`, `roks-tfsec` and `roks-checkov` with the rest of
the repository linters. Locally, without cloud access:

```bash
terraform -chdir=roks/terraform init -backend=false
terraform -chdir=roks/terraform validate
terraform fmt -check -recursive roks/terraform
make roks-tflint roks-tfsec roks-checkov
```
