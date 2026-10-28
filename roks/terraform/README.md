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
(looked up with a data source, never created). The only exceptions are the
registry service ID, its access policy and its API key: IAM identities are
account-level and have no resource group.

| Resource | Name |
|---|---|
| VPC (manual address prefixes) and its default ACL, security group, routing table | `<cluster_name>-vpc`, `<cluster_name>-default-acl`/`-default-sg`/`-default-rt` |
| One address prefix per zone | `<cluster_name>-prefix-<zone>` |
| One public gateway per zone (worker egress) and its floating IP | `<cluster_name>-pgw-<zone>`, `<cluster_name>-pgw-fip-<zone>` |
| One worker subnet per zone, attached to the zone's public gateway | `<cluster_name>-subnet-<zone>` |
| Cloud Object Storage instance (standard, global; ROKS on VPC needs it for the internal registry) | `<cluster_name>-cos` |
| ROKS cluster: `bx2.16x64`, 1 worker per zone across 3 zones, no entitlement (regular OpenShift license), public service endpoint on, outbound traffic protection off | `<cluster_name>` |
| `terraform_data.vpe_cleanup`: destroy-time hook that deletes the VPE gateways ROKS leaves in the VPC (see [Destroy](#destroy)) | - |
| `terraform_data.file_storage_addon`: enables the `vpc-file-csi-driver` add-on unless it is already enabled (see the storage notes below) | - |
| Optional, `deploy_postgres`: IBM Cloud Databases for PostgreSQL 15 (see [Optional managed services](#optional-managed-services)) | `<cluster_name>-postgres` |
| Optional, `deploy_redis`: IBM Cloud Databases for Redis | `<cluster_name>-redis` |
| IBM Cloud Container Registry namespace in the region's registry (`de.icr.io`), see [Container Registry](#container-registry-icr) | `<cluster_name>` |
| Service ID with Reader and Writer on that namespace only, and its API key (registry login) | `<cluster_name>-icr` |

`cluster_name` must start with `redhat-` (the pipeline uses
`redhat-roks-eic-pr<N>`), so every resource name starts with `redhat-`. Every
resource that supports tags gets `owner:redhat`, `project:sap-edge` and, when
`pr_number` is set, `pr:<N>`.

Cluster settings worth knowing:

- `disable_outbound_traffic_protection = true`: OpenShift 4.15+ on VPC blocks
  public egress from workers by default; the cluster needs it for
  OperatorHub, `registry.redhat.io`, SAP registries and ELM.
- `force_delete_storage = true`: asks ROKS to delete the volumes created by
  PVCs together with the cluster. VPC Block Storage volumes can still stay
  behind (even with a `Delete` storage class), which is why the
  `roks-teardown` task sweeps them afterwards (see [Destroy](#destroy)).
- `wait_till = "IngressReady"` with a 3 h create timeout.
- `openshift_version` only applies when the cluster is created
  (`ignore_changes = [kube_version]`). IBM applies master patch updates, and an
  admin may update the master to a newer minor version; a later apply leaves
  the version alone instead of trying a downgrade, which IBM rejects
  (`E0144 The cluster cannot be downgraded`). Upgrade an existing cluster with
  `ibmcloud ks cluster master update`, not by changing the variable.
- Storage:
  - ReadWriteOnce: VPC Block Storage, the cluster's default class
    `ibmc-vpc-block-10iops-tier`. On this 3-zone cluster prefer
    `ibmc-vpc-block-metro-10iops-tier` (`WaitForFirstConsumer`: the volume is
    created in the zone of the pod that uses it).
  - ReadWriteMany (shared file storage for EIC):
    `terraform_data.file_storage_addon` runs
    `scripts/enable-cluster-addon.sh`, which enables the IBM Cloud File Storage
    for VPC CSI driver add-on (`vpc-file-csi-driver`, default version) with
    the `ibmcloud` CLI unless it is already enabled, and waits for it. It
    provides the `ibmc-vpc-file-*` classes. The `ibm_container_addons`
    resource is not used: it fails on an add-on that is already enabled unless
    the version is pinned, and with its default `manage_all_addons = true` a
    later apply disables every add-on it does not list. EIC's
    shared file system does not work with them as they are: a cluster
    administrator has to fix the share's permissions once per EIC deployment.
    Avoid the `-retain` variants of either kind on these ephemeral clusters.

## Container Registry (ICR)

EIC validation on ROKS uses IBM Cloud Container Registry, not Quay; ELM is
given the registry server, user name and API key. `registry.tf` creates it on
every run (no flag):

- Namespace `<cluster_name>` in the registry of `region` (`eu-de` is
  `de.icr.io`; the `icr_registries` map in `registry.tf` lists the other
  regions, and a region without an entry fails the plan). Namespace names are
  4-30 characters and unique per registry region across all IBM Cloud
  accounts, which is why `cluster_name` is limited to 30 characters. The
  namespace is assigned to the resource group. The provider keeps namespace
  tags only in the Terraform state, so none are set.
- Service ID `<cluster_name>-icr` with one access policy: roles Reader (pull)
  and Writer (push) on service `container-registry`, resource type
  `namespace`, resource `<cluster_name>`, region `region`. Nothing broader.
- API key `<cluster_name>-icr` of that service ID. Log in with user
  `iamapikey` and the key as password, e.g.
  `terraform output -raw icr_api_key | docker login -u iamapikey --password-stdin de.icr.io`.
  The key is only returned when it is created, so it lives in the Terraform
  state (sensitive output `icr_api_key`).
- `terraform destroy` deletes the API key, the policy, the service ID and the
  namespace. Deleting the namespace deletes every image, the trash and the
  trust data in it.

## Optional managed services

`services.tf` holds the databases that mirror ROSA's `deployPostgres` and
`deployRedis`. Each resource and data source in it has `count = 0` unless its
flag is `true`, so with the Terraform default (both `false`) nothing is
created, and every output below is `null`. The ROKS pipeline sets both to
`true` by default.

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
  `postgres_admin_password`. The IBM provider accepts 15-72 characters of
  letters, digits, `-` and `_`, with at least one lower case letter, one upper
  case letter and one digit, and not starting with `-` or `_`; the variable
  enforces the same rules.
- Database: output `postgres_database` is the database IBM Cloud Databases
  creates in the instance (`ibmclouddb`, read from the connection data). EIC's
  database name is entered in ELM.
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
   For the registry it also needs, on Container Registry in `eu-de`, the
   Manager service role (namespaces) and the Administrator platform role (to
   grant the namespace policy), and on IAM Identity Service the Operator role
   (create the service ID and its API key), plus Service ID creator if the
   account restricts service ID creation.
3. A COS bucket for the Terraform state and HMAC credentials for it
   (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). The state holds the cluster
   admin certificate, the ingress secret, the registry API key and, when the
   optional services are on, the database passwords: keep the bucket private.
4. The Container Registry plan in `eu-de` is not Lite (500 MB, too small
   for the EIC images): `ibmcloud cr region-set eu-central`, `ibmcloud cr plan`,
   and `ibmcloud cr plan-upgrade standard` if needed.

The pipeline reads these credentials from one Secret in its namespace
(`roksCredentialsSecretName`, default `roks-ci-credentials`) with the keys
`IBMCLOUD_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and, when
`deployPostgres` is `"true"`, `POSTGRES_ADMIN_PASSWORD`; see the ROKS section
of `.tekton/README.md`.

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
key. The example PipelineRun sets `cancel-in-progress: "false"`, so a push
to the PR never kills a running apply or destroy: it starts a second run,
whose `terraform apply` stops on the lock. Do not push to the PR while
`deploy-roks` or `teardown-roks` runs (see [Destroy](#destroy) for the
recovery when a run was stopped anyway).

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

**Requirements for apply** (`terraform apply` and `make roks-apply`): `bash`,
`jq` and the `ibmcloud` CLI with the `container-service` plugin, logged in to
the account (see the destroy requirements below), for
`terraform_data.file_storage_addon`.

### Destroy

`make roks-destroy` runs `terraform destroy -refresh=false -var cluster_name=<CLUSTER>`
against the state key `roks/<CLUSTER>/terraform.tfstate`, the same as the
pipeline's `roks-teardown` task. It is the manual cleanup path for runs that
failed or were rejected (those keep the cluster for debugging). Without
`-refresh=false`, Terraform re-reads the admin-kubeconfig data source first,
which fails when the cluster is already (half) gone or the kubeconfig
directory is missing. Destroy works from the state: the `deploy_*` flags and
the PostgreSQL password are not needed. For a region other than `eu-de`, add
`ROKS_TF_ARGS="-var region=<region>"`.

**Requirements for destroy** (`terraform destroy` and `make roks-destroy`):
`bash`, `jq` and the `ibmcloud` CLI with the `vpc-infrastructure` plugin
(`ibmcloud plugin install vpc-infrastructure`), logged in to the account:
`ibmcloud login -r eu-de -g redhat-sap-edge-roks-ci` reads the key from
`IBMCLOUD_API_KEY`, so it is not on the command line.

**What `roks-teardown` adds** (the pipeline task; `make roks-destroy` does
none of this):

- Up to 3 destroy attempts. A state lock is not retried.
- Before the destroy, it reads the cluster ID (`terraform output -raw cluster_id`,
  else `roks-terraform-outputs.json` of `roks-deploy` if it names the same
  cluster). After the destroy, and between attempts once the cluster is gone
  from the state, it deletes the VPC load balancers and block volumes the
  cluster left behind: only in `redhat-sap-edge-roks-ci`, and only those whose
  name or tags contain the cluster ID (ROKS names its load balancers
  `kube-<cluster ID>-<service UID>`; the VPC Block CSI driver tags its volumes
  with the cluster ID). Without a cluster ID, or when `ibmcloudResourceGroup`
  is another group, it skips this sweep with a warning.
- It deletes the ConfigMap `cluster-info-roks-<cluster>` and the Secret
  `edgelm-kubeconfig-generated-<cluster>` (restricted kubeconfig of
  `ossm3-generate-sa-based-kubeconfig`) on the pipeline cluster, and the
  Secrets `eic-credentials-roks-<cluster>` and `eic-registry-roks-<cluster>`
  (on the pipeline cluster, or on the hub cluster when the optional
  `hubKubeconfigSecretName` is set), and removes
  `terraform.tfvars` (it may hold the PostgreSQL password) from the
  workspace.
- It exits 0 when the destroy succeeded, the sweep left nothing and every
  pipeline artifact was deleted. A skipped sweep (no usable cluster ID, or
  `ibmcloudResourceGroup` is not `redhat-sap-edge-roks-ci`) is only a
  warning: the task still exits 0, so check its log for leftovers. Otherwise
  it fails with a list of what is left and the recovery steps below.

After `make roks-destroy`, do the sweep by hand. Read the cluster ID before
the destroy (`terraform -chdir=roks/terraform output -raw cluster_id`), list
the cluster's leftovers, and delete each one with
`ibmcloud is load-balancer-delete <id> --force` or
`ibmcloud is volume-delete <id> --force`:

```bash
CLUSTER_ID=<cluster ID>
[[ "$CLUSTER_ID" =~ ^[a-z0-9]{16,40}$ ]] || { echo "need the cluster ID"; exit 1; }
ibmcloud is load-balancers --all-resource-groups --output JSON |
  jq -r --arg cid "$CLUSTER_ID" '.[] | select(.resource_group.name == "redhat-sap-edge-roks-ci" and (.name | contains($cid))) | "\(.id) \(.name)"'
ibmcloud is volumes --all-resource-groups --output JSON |
  jq -r --arg cid "$CLUSTER_ID" '.[] | select(.resource_group.name == "redhat-sap-edge-roks-ci" and ((.name | contains($cid)) or any((.user_tags // [])[]; contains($cid)))) | "\(.id) \(.name)"'
```

Then delete the pipeline artifacts: `oc delete configmap cluster-info-roks-<cluster> --ignore-not-found`
and `oc delete secret edgelm-kubeconfig-generated-<cluster> --ignore-not-found`
in the pipeline namespace, and
`oc delete secret eic-credentials-roks-<cluster> eic-registry-roks-<cluster> --ignore-not-found`
in the pipeline namespace (or on the hub cluster if the run set
`hubKubeconfigSecretName`).

**Do not push to the PR while `deploy-roks` or `teardown-roks` runs.** The
example PipelineRun sets `cancel-in-progress: "false"`, so a push does not
cancel the running pipeline; it starts a second run that fails on the state
lock without changing anything (a push while the first run waits at an
approval starts a second run against the same cluster: cancel one of them by
hand with `tkn pipelinerun cancel <name>`, never while it is in
`deploy-roks` or `teardown-roks`). A run stopped during apply or destroy
anyway (cancelled by hand, pod evicted, task timeout) can leave a stale lock
and a cluster that IBM Cloud created but the state does not record.

**Recovery when destroy fails or a run was stopped.** Run these from the
repository root after `make roks-init CLUSTER=<name>`.
`terraform -chdir=roks/terraform state list` shows what is left. Then,
depending on the error:

- State lock (`Error acquiring the state lock`, left by a run that was
  stopped during apply or destroy). First make sure that no other pipeline
  run or local command is using the state, then run
  `terraform -chdir=roks/terraform force-unlock <lock ID from the error>`.
- Cluster created by IBM Cloud but missing from the state (`state list` has
  no `ibm_container_vpc_cluster.cluster`, but
  `ibmcloud ks cluster get --cluster <name>` finds it). Import it with its
  ID and the same `-var cluster_name` as `make roks-destroy` (add
  `-var region=<region>` outside `eu-de`), then destroy:
  `terraform -chdir=roks/terraform import -var cluster_name=<name> ibm_container_vpc_cluster.cluster <cluster ID>`
  and `make roks-destroy CLUSTER=<name>`. Or delete the cluster directly with
  `ibmcloud ks cluster rm --cluster <name> --force-delete-storage`, wait until
  `ibmcloud ks cluster get --cluster <name>` no longer finds it, and run
  `make roks-destroy CLUSTER=<name>` for what the state still holds. Either
  way, do the leftover sweep above afterwards.
- Cluster already deleted outside Terraform. The IBM provider 2.8.0 fails on
  the 404 when it deletes the cluster:
  `terraform -chdir=roks/terraform state rm ibm_container_vpc_cluster.cluster`.
- ICR namespace or registry service ID deleted by hand (no 404 handling
  either):
  `terraform -chdir=roks/terraform state rm ibm_cr_namespace.icr` and
  `terraform -chdir=roks/terraform state rm ibm_iam_service_api_key.icr ibm_iam_service_policy.icr ibm_iam_service_id.icr`.

Then run `make roks-destroy CLUSTER=<name>` again.

**VPE cleanup hook:** when the first cluster is created in a VPC, ROKS creates
shared VPC endpoint gateways named `iks-*` (Container Registry, COS, cluster
service API, VPC API) and the security group `kube-vpegw-<vpc_id>`. ROKS does
not delete them when the cluster goes, and the VPC cannot be deleted while
they exist. `terraform_data.vpe_cleanup` (in `cluster.tf`) has a destroy-time
`local-exec` provisioner that runs `scripts/delete-vpe-gateways.sh <vpc_id> <region>`:
it deletes only the `iks-*` endpoint gateways of this VPC, waits up to 15
minutes until they are gone (requesting the deletion again on every poll for
those not yet being deleted, e.g. after a failed request), then deletes
`kube-vpegw-<vpc_id>`. The cluster
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
| `cluster_name` | (required) | Cluster name, name prefix and ICR namespace; `^[a-z][a-z0-9-]{0,28}[a-z0-9]$` (at most 30 characters), starts with `redhat-` |
| `region` | `eu-de` | IBM Cloud region |
| `resource_group` | `redhat-sap-edge-roks-ci` | Existing resource group |
| `openshift_version` | `4.21_openshift` | `<major>.<minor>_openshift`; used only when the cluster is created |
| `worker_flavor` | `bx2.16x64` | Worker flavor |
| `workers_per_zone` | `1` | Workers per zone (at least 2 in total) |
| `zones` | `["eu-de-1","eu-de-2","eu-de-3"]` | 1-3 zones of `region` |
| `pod_subnet` | `172.17.0.0/18` | Pod network (IBM-allowed ranges only, see above) |
| `pr_number` | `""` | Adds tag `pr:<N>` |
| `kubeconfig_dir` | `./.kube` | Existing directory for the admin kubeconfig |
| `deploy_postgres` | `false` | Optional IBM Cloud Databases for PostgreSQL |
| `deploy_redis` | `false` | Optional IBM Cloud Databases for Redis |
| `postgres_admin_password` | `""` (sensitive) | PostgreSQL admin password; required when `deploy_postgres`: 15-72 characters of letters, digits, `-`, `_`, with at least one lower case letter, one upper case letter and one digit, not starting with `-` or `_` |

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
| `postgres_database` | Database IBM Cloud Databases creates (`ibmclouddb`) |
| `postgres_admin_username` | `admin` |
| `postgres_ca_certificate_base64` | CA certificate of the PostgreSQL TLS certificate (not a secret) |
| `redis_host`, `redis_port` | Redis public hostname and port (TLS) |
| `redis_username` | `admin` |
| `redis_password` | Generated Redis admin password (sensitive) |
| `redis_ca_certificate_base64` | CA certificate of the Redis TLS certificate (not a secret) |
| `icr_registry` | Registry host (`de.icr.io` for `eu-de`) |
| `icr_namespace` | ICR namespace (`<cluster_name>`) |
| `icr_username` | `iamapikey` |
| `icr_api_key` | API key of the registry service ID, the registry password (sensitive) |

The database outputs are `null` when their flag is `false`. Read sensitive
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
  icr_registry icr_namespace icr_username icr_api_key; do
  grep -q "^output \"${output}\"" roks/terraform/outputs.tf ||
    echo "missing output: ${output}"
done
```

A plan with the flags turned on needs credentials:
`make roks-plan CLUSTER=<name> ROKS_TF_ARGS="-var deploy_postgres=true -var deploy_redis=true"`
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
