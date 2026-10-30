<!--
SPDX-FileCopyrightText: 2024 SAP edge team
SPDX-License-Identifier: Apache-2.0
-->

# Tekton Pipelines

CI/CD pipelines for deploying and testing SAP Edge Integration Cell on ARO, ROSA, and HCP clusters.

## Pipelines

### ARO (Azure Red Hat OpenShift)

| Pipeline | Purpose |
|----------|---------|
| `aro-eic-full-test-pipeline.yaml` | Full ARO deployment with EIC services → endpoint testing → cleanup |
| `aro-edgelm-validation-pipeline.yaml` | ARO + Quay deployment → edgelm validation → status reporting |

### ROSA (Red Hat OpenShift on AWS)

| Pipeline | Purpose |
|----------|---------|
| `rosa-eic-full-test-pipeline.yaml` | Full ROSA deployment with EIC services → endpoint testing → cleanup |
| `rosa-edgelm-validation-pipeline.yaml` | ROSA + Quay deployment → edgelm validation → status reporting |

### ROKS (Red Hat OpenShift on IBM Cloud)

| Pipeline | Purpose |
|----------|---------|
| `roks-eic-full-test-pipeline.yaml` | Full ROKS deployment with EIC services → endpoint testing → cleanup |

### HCP (Hosted Control Plane)

| Pipeline | Purpose |
|----------|---------|
| `hcp-kubevirt-validation-pipeline.yaml` | HCP KubeVirt cluster deployment and validation |
| `hcp-ossm3-validation-pipeline.yaml` | HCP KubeVirt + OSSM3 restricted-access setup, EIC services, endpoint tests, and teardown |

### Common

| Pipeline | Purpose |
|----------|---------|
| `endpoint-test-pipeline.yaml` | Standalone endpoint testing for existing clusters |

## Tasks

### ARO Tasks
- `aro-deploy-with-eic-services`: Deploy ARO with PostgreSQL/Redis (Bicep)
- `aro-deploy-only`: Deploy ARO without external services
- `aro-validate-task`, `aro-validate-and-create-configmap-task`: Validate deployment
- `aro-quay-deploy-task`: Deploy Quay registry
- `aro-deployment-status-report-task`: Generate deployment reports
- `aro-teardown-task`: Clean up resources

### ROSA Tasks
- `rosa-deploy-with-eic-services`: Deploy ROSA with PostgreSQL/Redis
- `rosa-validate-and-get-access-task`, `rosa-validate-and-create-configmap-task`: Validate deployment
- `rosa-quay-deploy-task`: Deploy Quay registry
- `rosa-deployment-status-report-task`: Generate deployment reports
- `rosa-teardown-task`: Clean up resources

### ROKS Tasks
- `roks-deploy-task`: Deploy ROKS with Terraform (VPC, cluster, ICR namespace and service ID, PostgreSQL/Redis via IBM Cloud Databases) and fetch the admin kubeconfig into the workspace
- `roks-validate-and-get-access-task`: Validate cluster access, switch the workspace to a ServiceAccount token kubeconfig and store it with the database connection data in the Secret `eic-credentials-roks-<cluster>` (on the hub cluster when `hubKubeconfigSecretName` is set)
- `roks-validate-and-create-configmap-task`: Find EIC host and ingress address for tests
- `roks-registry-access-task`: Store the ICR access for ELM (server, namespace, user, API key from the Terraform state) in the Secret `eic-registry-roks-<cluster>` (on the hub cluster when `hubKubeconfigSecretName` is set), and the Redis password in `eic-credentials-roks-<cluster>`
- `roks-sap-browser-access-task`: Optional browser automation: let the runner ServiceAccount read this run's three Secrets (per-run Role) and read the cluster's Edge Node ID label; does nothing when the browser is off (`sapBrowserMode` disabled or no `sapBrowserImage`)
- `roks-sap-browser-task`: Optional browser automation: Playwright browser for the ELM steps (deploy or teardown phase) behind a per-run Route with the OpenShift OAuth proxy; the step always exits 0 and reports the result `outcome` (pod-level failures still fail the task)
- `roks-teardown-task`: Destroy infrastructure and clean up artifacts

### HCP Tasks
- `hcp-create-hosted-cluster-task`: Create HCP cluster
- `hcp-wait-cluster-ready-task`: Wait for cluster readiness
- `hcp-deploy-postgres-task`, `hcp-deploy-redis-task`: Deploy external services
- `hcp-get-all-accesses-task`: Retrieve service credentials
- `hcp-validate-and-create-configmap-task`: Validate and configure
- `hcp-teardown-task`: Clean up resources

### OSSM3 Tasks
- `ossm3-verify-operators-task`: Verify Service Mesh 3.x operators are installed
- `ossm3-prepare-namespaces-task`: Service Mesh labels and SCC annotations on the namespaces the SAP restricted-resources bundles created (never creates a namespace; one that does not exist yet is skipped until a later bundle creates it)
- `ossm3-configure-mesh-task`: Deploy IstioCNI and Istio control plane, and add the existing application namespaces to the mesh
- `ossm3-apply-rbac-task`: Apply RBAC permissions from SAP Note 3618713 resources
- `ossm3-generate-sa-based-kubeconfig-task`: Generate SA-based restricted kubeconfig for ELM registration
- `ossm3-wait-for-restricted-resources-task`: Wait until every given component folder under the run's S3 prefix holds a restricted-resources `.zip` (ROKS pipeline: `wait-elm-zip`, `wait-eic-zip`); prints the instructions with the upload plan once, retries failed listings

### Common Tasks
- `endpoint-tests`: Test EIC API endpoints
- `rate-limit-test`: Validate API rate limiting
- `jira-add-comment-custom`: Update Jira tickets
- `git-clone`: Clone repository
- `manual-approval-gate`: Manual approval checkpoint

## Usage

### 1. Create Required Secrets

**Common secrets:**
```bash
# Red Hat pull secret
oc create secret generic redhat-pull-secret \
  --from-literal=PULL_SECRET='{"auths":{"registry.redhat.io":{"auth":"..."}}}'

# Quay admin credentials
oc create secret generic quay-admin-secret \
  --from-literal=password="quay-admin-password" \
  --from-literal=email="admin@example.com"

# EIC authentication secret
oc create secret generic eic-auth-secret \
  --from-literal=authKey="your-eic-auth-key"
```

**ARO-specific secrets:**
```bash
oc create secret generic azure-sp-secret \
  --from-literal=CLIENT_ID="your-client-id" \
  --from-literal=CLIENT_SECRET="your-client-secret" \
  --from-literal=TENANT_ID="your-tenant-id" \
  --from-literal=ARO_RESOURCE_GROUP="aro-sapeic" \
  --from-literal=ARO_DOMAIN="saponrhel.org"

oc create secret generic azure-postgres-admin-password \
  --from-literal=password="your-secure-password"
```

**ROSA-specific secrets:**
```bash
oc create secret generic aws-credentials-secret \
  --from-literal=AWS_ACCESS_KEY_ID="your-access-key" \
  --from-literal=AWS_SECRET_ACCESS_KEY="your-secret-key"

oc create secret generic redhat-token-secret \
  --from-literal=REDHAT_OCM_TOKEN="your-ocm-token"

# Note: AWS RDS PostgreSQL does NOT allow: / @ " (space)
oc create secret generic rosa-postgres-admin-password \
  --from-literal=POSTGRES_ADMIN_PASSWORD="YourSecure-Password123!"
```

**ROKS-specific secrets** (one Secret, pipeline param `roksCredentialsSecretName`):
```bash
# IBMCLOUD_API_KEY: IBM Cloud API key (preferably a service ID's key scoped to the resource group)
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY: COS HMAC credentials of the Terraform state bucket
# POSTGRES_ADMIN_PASSWORD: PostgreSQL admin password for IBM Cloud Databases, only
#   read when deployPostgres is "true" (leave the key out otherwise).
#   IBM provider rule: 15-72 characters of letters, digits, - and _,
#   with ≥1 lowercase, ≥1 uppercase, ≥1 digit, not starting with - or _
oc create secret generic roks-ci-credentials \
  --from-literal=IBMCLOUD_API_KEY="your-ibmcloud-api-key" \
  --from-literal=AWS_ACCESS_KEY_ID="your-hmac-access-key-id" \
  --from-literal=AWS_SECRET_ACCESS_KEY="your-hmac-secret-access-key" \
  --from-literal=POSTGRES_ADMIN_PASSWORD="YourSecure-Password123"
```

**HCP-specific secrets:**
```bash
# Hub cluster kubeconfig (for accessing the management cluster)
oc create secret generic hub-admin-kubeconfig \
  --from-file=kubeconfig=/path/to/hub-kubeconfig
```

**OSSM3 prerequisites:**

The OSSM3 pipelines require:

1. **Service Mesh 3.x operator** installed on the target cluster via OperatorHub before running the pipeline.

2. **RBAC resources ConfigMap** created from SAP Note 3618713 `resources.zip`:
```bash
# Download and extract resources.zip from SAP Note 3618713
unzip resources.zip -d /tmp/rbac-resources/

# Create ConfigMap from extracted YAML files
oc create configmap ossm3-rbac-resources \
  --from-file=/tmp/rbac-resources/
```

The ConfigMap is mounted as a workspace in the pipeline and contains CRDs, ClusterRoles, ClusterRoleBindings, Roles, RoleBindings, and optional webhook YAML files.

### 2. Deploy Pipeline Resources
```bash
oc apply -f .tekton/tasks/
oc apply -f .tekton/pipelines/
```

### 3. Run a Pipeline
```bash
# Apply a PipelineRun (use 'oc create' for generateName-based runs)
oc create -f .tekton-examples/<pipeline-run>.yaml

# Monitor
tkn pipelinerun logs <pipelinerun-name> -f
tkn pipelinerun list
```

**Example PipelineRuns** are in `.tekton-examples/`:
- `hcp-kubevirt-validation-pipelinerun.yaml` - HCP KubeVirt validation
- `hcp-ossm3-validation-pipelinerun.yaml` - HCP KubeVirt + OSSM3 restricted-access setup

### 4. Manual Approvals
```bash
oc get approvaltasks
oc patch approvaltask <name> --type=merge -p '{"spec":{"approved":true}}'
```

## Multi-EIC restricted resources

Two pipelines deploy more than one Edge Integration Cell (EIC) on one cluster:

- **Topology A, shared core:** `hcp-ossm3-dedicated-validation-pipeline`. One
  Edge Node (a shared `edgelm`), one dedicated mesh, N cells (`cellCount`,
  default `2`).
- **Topology B, 1:1:1 stacks:** `hcp-ossm3-multi-stack-validation-pipeline`. An
  Edge Node, ELM and mesh per cell, two stacks (KBA 7149262 "Scenario 2:
  Multiple Edge Nodes with Dedicated Meshes"; ELM 1.64 and EIC 8.48 or later).

SAP's restricted-resources bundles create their namespaces with the labels
`edgelm.sap.com/product=edgelm` and `edgelm.sap.com/edge-node-id=<uuid>`, and
their `apply-restricted-resources.sh` refuses a namespace that belongs to
another Edge Node. Cells therefore need distinct namespace names. Cluster-scoped
resources (CRDs, the ELM ClusterRole and ClusterRoleBinding) exist once per
cluster, so the ELM bundle is applied first.

### Namespace names

Cell N appends `-N` to each base name. The names are chosen when the bundle is
generated in ELM and must follow this scheme:

| Role                | Base name             | Cell/stack 1            | Cell/stack 2            |
|---------------------|-----------------------|-------------------------|-------------------------|
| main                | `edge-icell`          | `edge-icell-1`          | `edge-icell-2`          |
| secrets             | `edge-icell-secrets`  | `edge-icell-secrets-1`  | `edge-icell-secrets-2`  |
| ela                 | `edge-icell-ela`      | `edge-icell-ela-1`      | `edge-icell-ela-2`      |
| services            | `edge-icell-services` | `edge-icell-services-1` | `edge-icell-services-2` |
| gateways            | `istio-gateways`      | `istio-gateways-1`      | `istio-gateways-2`      |
| edgelm (topology A) | `edgelm`              | shared `edgelm`         | shared `edgelm`         |
| edgelm (topology B) | `edgelm`              | `edgelm-1`              | `edgelm-2`              |

The tasks find the role by stripping the trailing `-<digits>`, for example
`edge-icell-services-2` → `edge-icell-services`.

### S3 layout

One prefix per cluster deployment (pipeline parameter `s3Prefix`), one folder
per component:

```text
# Topology A (shared ELM, one mesh, N cells)
restricted-resources/pr<N>/
  elm/            restricted-resources-Edge_Lifecycle_Management-<ver>.zip
  edge-icell-1/   restricted-resources-Edge_Integration_Cell-<ver>.zip
  edge-icell-2/   restricted-resources-Edge_Integration_Cell-<ver>.zip

# Topology B (an ELM and a mesh per stack)
restricted-resources/pr<N>-multi-stack/
  elm-1/          restricted-resources-Edge_Lifecycle_Management-<ver>.zip
  edge-icell-1/   restricted-resources-Edge_Integration_Cell-<ver>.zip
  elm-2/          restricted-resources-Edge_Lifecycle_Management-<ver>.zip
  edge-icell-2/   restricted-resources-Edge_Integration_Cell-<ver>.zip
```

- One bundle zip per folder; the latest version in a folder wins. To add a
  cell, add a folder; to upgrade a cell, put the newer zip into its folder.
- Topology A creates the folders listed in `restrictedResourcesComponents`
  (for example `elm edge-icell-1 edge-icell-2`) and pauses at
  `approval-upload-restricted-resources` with upload instructions and each
  folder's contents. After the approval, `apply-rbac` fails if a listed folder
  holds no zip.
- Topology B creates the folders of `elmRestrictedResourcesComponents`
  (`elm-1 elm-2`) and `eicRestrictedResourcesComponents`
  (`edge-icell-1 edge-icell-2`) and applies them in two passes, because the EIC
  zips can only be downloaded after the Edge Nodes are registered:
  1. `wait-elm-zips` waits until each ELM folder holds a zip, `apply-rbac-elm`
     applies them, then the meshes, the `edgelm-N` labels and one restricted
     kubeconfig per Edge Node follow, then PostgreSQL and Redis/Valkey.
  2. Register both Edge Nodes with their kubeconfigs, deploy EIC in ELM and
     upload the EIC zips: `wait-eic-zips` waits for them, `apply-rbac-eic`
     applies them and `prepare-namespaces-multi-stack-eic` puts the EIC
     namespaces on their meshes. Confirm the EIC resources in ELM once
     `approval-elm-eic-iflow-deployed` is waiting.

  The waits are tasks, not approvals; their logs show the upload plan. Zips
  from an earlier run of the same PR stay in the folders, so a folder that
  already holds a zip does not wait.
- `apply-rbac`, `apply-rbac-elm` and `apply-rbac-eic`
  (`ossm3-download-and-apply-rbac`, parameter `requiredComponents`) download
  only the listed folders; other folders below the prefix are never applied.
- An empty `restrictedResourcesComponents` means a flat prefix: only the zips
  directly under `s3Prefix` are applied, as one component. The single-EIC
  pipelines (`hcp-ossm3-validation`, ARO, ROSA) use `restricted-resources/`
  this way.

### Apply order

In each component, `apply-rbac` picks the latest bundle per resource type and
applies ELM first, then a standalone gateways bundle if there is one, then the
EIC cells ordered by name. It classifies bundles by the resource type in the zip
name (`Edge_Lifecycle_Management`, `Edge_Integration_Cell`, …). In the current
bundle format, the `istio-gateways` namespace and its RBAC ship inside each EIC
bundle, so there is no separate gateways folder. Each bundle is applied with its
own `apply-restricted-resources.sh --yes`.

### Mesh labels and SCC annotations

The same values apply to every cell:

| Base role             | `istio.io/rev` | `istio-discovery` | SCC `uid-range` | SCC `supplemental-groups` |
|-----------------------|----------------|-------------------|-----------------|---------------------------|
| `edgelm`              | yes            | yes               | -               | `67000/1000`              |
| `edge-icell`          | yes            | yes               | `10000/100`     | `1000/100`                |
| `edge-icell-ela`      | yes            | yes               | `100000/1000`   | `100002/1000`             |
| `edge-icell-services` | yes            | yes               | `1000000/1000`  | `1000002/1000`            |
| `edge-icell-secrets`  | no             | yes               | -               | -                         |
| `istio-gateways`      | yes            | yes               | -               | -                         |

The secrets namespaces are in the mesh's discovery scope but get no sidecars
(KBA 7131840).

- Topology A: `ossm3-prepare-namespaces-dedicated` finds the SAP namespaces by
  `edgelm.sap.com/product=edgelm`, replaces `istio-injection` with
  `istio.io/rev=sap-mesh-istio` and sets the SCC annotations per role. Then
  `ossm3-configure-dedicated-mesh` creates the control plane and labels all SAP
  namespaces `istio-discovery=sap-edge-mesh`.
- Topology B runs the other way round, because the revision label is read from
  the running control plane: `ossm3-configure-multi-stack-mesh` creates one
  control plane per stack (namespace `istio-system-sap-edge-N`, Istio
  `sap-mesh-istio-N`, selector `istio-discovery=sap-edge-mesh-N`), then
  `ossm3-prepare-namespaces-multi-stack` labels each stack's namespaces with the
  active revision of its mesh: `edgelm-N` after the ELM pass, and again
  (`prepare-namespaces-multi-stack-eic`) the EIC namespaces after the EIC pass.

### Backing services per cell

- Redis/Valkey: one instance per cell (`--instance eic-N`, namespace
  `<default namespace>-eic-N`).
- PostgreSQL: one instance, shared by all cells.
- Each cell's credentials are in the Secret
  `eic-credentials-hcp-<cluster>-eic-N`. Its `kubeconfig` key holds the
  restricted kubeconfig of the cell's Edge Node: `edgelm-kubeconfig` in
  topology A, `edgelm-N-kubeconfig` in topology B.

## Pipeline Features

### Timeouts
- **Pipeline total**: 720h (30 days) - allows for long manual approval windows
- **Individual tasks**: 168h (7 days) - prevents individual task hangs
- **Manual approvals**: 168h (7 days) - reasonable approval window

### Monitoring
- Comprehensive logging throughout all tasks
- Jira integration for status updates
- Detailed status reports with component health
- Machine-readable status files for automation

### Security
- All credentials handled via Kubernetes secrets
- No credentials exposed in logs
- Temporary files cleaned up automatically
- Azure CLI login scoped to specific operations

## Configure worker open-file limits before installation

On a fresh **self-managed OpenShift cluster**, run
[`configure_worker_nofile.sh`](../edge-integration-cell/configure_worker_nofile.sh)
before installing PostgreSQL, Redis and EIC. It checks the actual limits in a new
container on every worker and configures CRI-O only when a worker's limits fall
below `nofile=4096:1048576` (soft:hard). These are the
[Solace-recommended limits](https://docs.solace.com/Software-Broker/System-Scaling-Parameters.htm).

Requirements: Bash, `oc`, `jq`, standard `awk`/`base64` utilities, GNU `timeout`
(or `gtimeout`), and cluster-admin access. On macOS, install Homebrew `coreutils`
for GNU `timeout`. The script has no Python runtime dependency. Log in to the
target cluster first; it uses the current context and honors `KUBECONFIG`.
Run from the repository root:

```bash
# Optional: inspect workers and validate any proposed change with the API server.
bash edge-integration-cell/configure_worker_nofile.sh --dry-run

# Detect, configure if necessary, wait for the rollout, and verify the limits.
bash edge-integration-cell/configure_worker_nofile.sh
```

Inspection creates temporary `oc debug node` pods, including in dry-run mode.
When a change is needed, the script creates or updates
`96-worker-crio-limit-files`, managing
`/etc/crio/crio.conf.d/99-eic-nofile.conf`. It preserves other CRI-O ulimit entries
and higher existing `nofile` values. Changing the MachineConfig can drain and
reboot workers. See Red Hat's
[CRI-O ulimit guidance](https://access.redhat.com/solutions/6243491) for the target
OpenShift release.

The script waits for the requested rendered configuration, every worker to be
Ready and schedulable, and the pool to finish updating. It then checks fresh
container limits and the running CRI-O configuration on every worker. If the
limits are already sufficient, it verifies readiness and skips the change.
Successful execution ends with **`All done`**; PostgreSQL, Redis and EIC can then
be installed. No PDB changes are needed for this fresh-cluster preparation because
the database workloads have not been installed yet.

The default timeout is 30 minutes; use `--timeout 3600` for an hour. A timeout,
degraded or paused pool, conflicting configuration, or failed verification returns
a nonzero exit status without reporting success. An applied MachineConfig remains
in place if the script is interrupted or times out; resolve the reported issue
and rerun it.

`--pool <name>` selects a custom worker pool and its matching MachineConfig role
label. The script requires that label to select only the requested pool; it stops
if the default `worker` label also affects custom pools. Configure each pool with
an exclusive role label separately. Control-plane nodes, ARO/ROSA and hosted
control plane clusters require their own configuration procedures.

## Troubleshooting

### Common Issues
1. **Task timeouts**: Check individual task logs for specific failures
2. **Secret not found**: Verify all required secrets are created
3. **Azure authentication**: Check service principal permissions 
4. **Quay deployment fails**: Verify Azure storage account creation
5. **Pod status check fails**: Check if edgelm namespace exists

### PostgreSQL or Redis PDB blocks a node rollout

For the in-cluster services deployed by the HCP tasks, use
[`fix_pdb_for_node_rollout.sh`](../edge-integration-cell/fix_pdb_for_node_rollout.sh).
It defaults to PostgresCluster `edgedb` in `sap-eic-external-postgres` and
RedisEnterpriseCluster `rec` in `sap-eic-external-redis`. Use `oc` (or `kubectl`)
and `jq`, with `KUBECONFIG` pointing to the cluster running the database pods.
For HCP, this is the hosted cluster, not the management cluster.

**This removes disruption protection and can interrupt PostgreSQL and Redis,
including all replicas of an HA deployment. Changes remain in place after the
rollout; the script does not restore the original budgets.**

```bash
# Preview and validate against the installed APIs without changing resources.
bash edge-integration-cell/fix_pdb_for_node_rollout.sh --dry-run

# Apply once; no confirmation prompt or restore step.
bash edge-integration-cell/fix_pdb_for_node_rollout.sh

# If an operator resets the budgets, reapply during the rollout until Ctrl-C.
bash edge-integration-cell/fix_pdb_for_node_rollout.sh --watch 5
```

Use `--postgres-namespace`, `--postgres-cluster`, `--redis-namespace` and
`--redis-cluster` for custom deployments (for example, a Redis instance namespace).
For services deployed with `--instance eic01` and `--instance eic02`, run:

```bash
bash edge-integration-cell/fix_pdb_for_node_rollout.sh \
  --redis-namespace sap-eic-external-redis-eic01
bash edge-integration-cell/fix_pdb_for_node_rollout.sh \
  --redis-namespace sap-eic-external-redis-eic02
```

Both commands include the shared PostgresCluster `edgedb` in
`sap-eic-external-postgres`, which hosts databases `edgedb-eic01` and `edgedb-eic02`.
The second command skips PostgreSQL settings already applied by the first.
Each command also handles its selected Redis namespace. Add `--dry-run` to preview.

Only PDBs directly owned by these two custom resources are patched. The script
sets `minAvailable: 0` and removes `maxUnavailable` atomically, leaving selectors
and other PDB settings intact. Other PDBs shown in the status output are unchanged.

For Crunchy, it also sets `spec.instances[*].minAvailable` and, when present,
`spec.proxy.pgBouncer.minAvailable` to `0`. The operator then removes those PDBs;
this is the [documented Crunchy setting](https://access.crunchydata.com/documentation/postgres-operator/latest/architecture/high-availability).
The script checks that the installed CRD accepts these fields before changing the
PostgresCluster. Redis is patched directly, so its operator can revert the change.
Watch mode re-applies patches but cannot guarantee a window for eviction if an
operator immediately resets them. Stopping it leaves the latest settings in place.
GitOps or a later manifest apply can also overwrite changes; reflect the intended
PostgreSQL settings in your deployment source if GitOps manages the cluster.

```bash
oc get pdb -n sap-eic-external-postgres
oc get pdb -n sap-eic-external-redis
oc get nodes
# Self-managed OCP with a worker MachineConfigPool:
oc get mcp worker
```

Allow PDB status to catch up. A remaining PDB with healthy matching pods should
show positive `ALLOWED DISRUPTIONS`; a PDB removed by Crunchy no longer blocks
eviction. If draining still fails, inspect the particular PDB named in the drain
error and check for overlapping budgets, unavailable pods or an operator resetting
the policy. This script does not drain nodes, change CRI-O limits or verify the
Solace startup issue. See [Kubernetes PDB guidance](https://kubernetes.io/docs/tasks/run-application/configure-pdb/).

#### Redis pods remain Terminating after eviction

Check the specific instance without changing resources:

```bash
bash edge-integration-cell/fix_pdb_for_node_rollout.sh --status \
  --redis-namespace sap-eic-external-redis-eic01
bash edge-integration-cell/fix_pdb_for_node_rollout.sh --status \
  --redis-namespace sap-eic-external-redis-eic02
```

The script follows Redis pod ownership through its StatefulSet. It exits with
code `2` when a selected Redis pod has been terminating for at least five minutes
(or the termination duration cannot be determined). Apply, dry-run and watch modes
also stop before further patches in this situation. The five-minute threshold is
a diagnostic signal, not a deadline for killing a database process.

A drain can pass the PDB check and still wait for Redis to shut down. In a
single-node Redis cluster, the `preStop` hook can repeatedly fail to move shards
with `Cannot evict shards from node:1`. If the pod has
`terminationGracePeriodSeconds: 31536000`, Kubernetes can wait up to a year for
the shutdown hook. The pod's `deletionTimestamp` includes the remaining grace
period, so it may point into the next year. Zero `ALLOWED DISRUPTIONS` while the
only pod is terminating does not by itself prove the PDB is the current blocker.

```bash
oc exec -n sap-eic-external-redis-eic01 rec-0 -c redis-enterprise-node -- \
  tail -n 30 /var/opt/redislabs/log/prestop_exec_action.log
```

Check effective Redis database persistence and replication before stopping the
pod: a persistent volume does not enable database persistence. A single Redis
node with persistence disabled has no durable copy guaranteed to survive a
restart. PDB/status modes do not delete pods or shorten termination automatically.

After choosing a shutdown policy appropriate for the database, the supported REC
field `spec.redisEnterpriseTerminationGracePeriodSeconds` can bound the grace
period of future pods. It does not shorten an already-pending deletion, which
needs separate recovery. See the [Redis REC API](https://redis.io/docs/latest/operate/kubernetes/reference/api/redis_enterprise_cluster_api/)
and [Kubernetes container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/).

#### Recover disposable single-node Redis after the rollout

For test clusters where Redis data can be discarded, this workflow can recover
single-node Redis. Expect downtime during worker maintenance.
Keep the REC persistent volume: it holds the cluster configuration needed for
recovery even when database persistence is disabled.

After the worker MachineConfigPool finishes updating, a replacement single-node
Redis pod can remain unready with `pod is not yet bootstrapped` and bootstrapper
logs saying `No pod has been labeled as master pod yet`. Use the explicit
disposable-data recovery mode:

```bash
# Inspect and validate the plan first; this makes no changes.
bash edge-integration-cell/fix_pdb_for_node_rollout.sh \
  --recover-disposable-redis --dry-run \
  --redis-namespace sap-eic-external-redis-eic01

# Recover each selected test instance. Databases in recovery restart EMPTY.
bash edge-integration-cell/fix_pdb_for_node_rollout.sh \
  --recover-disposable-redis \
  --redis-namespace sap-eic-external-redis-eic01
bash edge-integration-cell/fix_pdb_for_node_rollout.sh \
  --recover-disposable-redis \
  --redis-namespace sap-eic-external-redis-eic02
```

This mode requires Python 3 in addition to the normal CLI dependencies. It checks
that the `worker` MachineConfigPool is updated and healthy, the REC has exactly
one node and persistent storage, and the Redis pod is running on a ready,
schedulable worker. Use `--machine-config-pool NAME` for another worker pool and
`--recovery-timeout SECONDS` to change the default 600-second recovery timeout.

For the known lost-master bootstrap failure, it requests the operator's
`spec.clusterRecovery: true` procedure, waits for the REC to return to `Running`
and its pod to become Ready, then reads current database state from Redis. Each
database in `recovery` is restored with `rladmin recover db db:<id> only_configuration`.
This discards the data for those databases, including any saved database data.
Existing active databases are left alone; rerunning resumes an incomplete
recovery instead of resetting a healthy instance. The command preserves the
configuration restored by Redis, including endpoints and credentials. See
[Redis cluster recovery](https://redis.io/docs/latest/operate/kubernetes/re-clusters/cluster-recovery/)
and [database configuration recovery](https://redis.io/docs/latest/operate/rs/databases/recover/).

Recovery mode changes only the selected Redis cluster. It does not change
PostgreSQL or PDB settings, delete PVCs, drain nodes, or release a stuck shutdown
hook. If a pod is still terminating or the worker rollout is incomplete, resolve
that first using the diagnosis above. HA clusters and unrelated bootstrap failures
are rejected. Default PDB mode, `--status`, and `--watch` never initiate recovery.

For disposable test data, `replication: false` is also acceptable on a three-node
REC if database downtime and empty recovery are acceptable. Three REC nodes
provide cluster quorum; database `spec.replication: true` adds a replica shard
for availability of each database. It is not required just to restart empty.
Database persistence is another, separate choice. Our `--type ha` option currently
selects three REC nodes but uses the same database manifest, which does not enable
replication. See the [Redis database API](https://redis.io/docs/latest/operate/kubernetes/reference/api/redis_enterprise_database_api/).

Run the offline shutdown and recovery regression tests with:

```bash
python3 -B -m unittest discover \
  -s edge-integration-cell/tests -p 'test_*.py' -v
```

### Debugging Commands
```bash
# Get pipeline run details
tkn pipelinerun describe <pipelinerun-name>

# Get task run logs
tkn taskrun logs <taskrun-name>

# Check pipeline status
oc get pipelineruns

# Check approval tasks
oc get approvaltasks
```

## Infrastructure Configuration

### ARO (Azure - Bicep)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `deployPostgres` | Deploy Azure Database for PostgreSQL | `true` |
| `deployRedis` | Deploy Azure Cache for Redis | `true` |
| `deployQuay` | Deploy Azure Storage Account for Quay | `true` |

```bash
make aro-destroy              # Complete destroy
make aro-resource-group-delete # Fast cleanup
make aro-delete-cluster       # Delete cluster only
```

### ROSA (AWS - Terraform/CloudFormation)

ROSA pipelines deploy AWS RDS PostgreSQL and ElastiCache Redis.

```bash
make rosa-destroy             # Complete destroy
make rosa-delete-cluster      # Delete cluster only
```

### ROKS (IBM Cloud - Terraform)

ROKS pipelines deploy a VPC cluster with IBM Cloud Databases for PostgreSQL and Redis, plus an IBM Cloud Container Registry namespace.

**One-time setup:**

1. **Resource group** `redhat-sap-edge-roks-ci` (exists). Every resource the pipeline creates is named `redhat-<cluster>-*` and, where the resource supports tags, tagged `owner:redhat`, `project:sap-edge`, `pr:<N>`, so IBM colleagues recognize them.

2. **Service ID** (e.g. `redhat-sap-edge-roks-ci`) with an API key and access:
   - **VPC Infrastructure Services** in the resource group
   - **Kubernetes Service** in the resource group, including **Administrator** platform role (to manage the region/resource-group infrastructure API key)
   - **Cloud Object Storage** in the resource group
   - **Databases for PostgreSQL** and **Databases for Redis** in the resource group
   - **Container Registry** in `eu-de`: **Manager** service role (create namespaces) and **Administrator** platform role (create namespace access policies)
   - **IAM Identity Service**: **Operator** role (create service IDs and API keys for the per-run ICR access)

3. **COS bucket** for Terraform state (one state per cluster under `roks/<clusterName>/terraform.tfstate`) with HMAC credentials. Keep the bucket private: the state holds the cluster admin certificate, registry API keys and database passwords.

4. **One credentials Secret** `roks-ci-credentials` in the pipeline namespace (pipeline param `roksCredentialsSecretName`), see [ROKS-specific secrets](#1-create-required-secrets) for the `oc create secret` command:
   - `IBMCLOUD_API_KEY`: the service ID's API key
   - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`: the HMAC credentials of the state bucket
   - `POSTGRES_ADMIN_PASSWORD`: only read when `deployPostgres` is `"true"` (the key may be left out otherwise), meeting the IBM provider rule: 15–72 characters of letters, digits, `-`, `_`, with at least one lowercase letter, one uppercase letter and one digit, not starting with `-` or `_`, and no trailing newline (`--from-literal` adds none).

5. **Verify IBM Cloud Container Registry plan** in `eu-de` is not Lite (Lite = 500 MB storage, too small for EIC image mirroring):
   ```bash
   ibmcloud cr region-set eu-central
   ibmcloud cr plan
   # Upgrade to standard if needed: ibmcloud cr plan-upgrade standard
   ```

6. **SAP `httpbinipfilter` iFlow allowlist** (one-time addition): add `172.17.0.0/18` (ROKS pod network) and `10.0.0.0/16` (VPC) so endpoint tests can reach the iFlow.

7. The existing `eic-auth-secret` (shared with other pipelines). No hub cluster is needed. Only if the credentials and registry Secrets should go to a hub cluster: a Secret in the pipeline namespace with the hub kubeconfig (key `kubeconfig`, `config` or `value`), passed as the optional pipeline param `hubKubeconfigSecretName` (default empty).

**What the pipeline produces for ELM** (the Secrets `eic-registry-roks-<cluster>` and `eic-credentials-roks-<cluster>` are in the pipeline namespace on the pipeline cluster, or on the hub cluster when `hubKubeconfigSecretName` is set; `roks-teardown` deletes them from the same place):

- Restricted kubeconfig Secret `edgelm-kubeconfig-generated-<cluster>` (pipeline namespace, pipeline cluster) for cluster registration
- IBM Cloud Container Registry Secret `eic-registry-roks-<cluster>`: keys `server` (`de.icr.io`), `namespace` (the cluster name), `username` (`iamapikey`) and `password` (API key of the run's ICR service ID). Terraform in `roks-deploy` creates the namespace and the service ID; `roks-registry-access` stores the Secret.
- Secret `eic-credentials-roks-<cluster>`: token kubeconfig, PostgreSQL/Redis connection data and `redis-password`
- PostgreSQL admin password: key `POSTGRES_ADMIN_PASSWORD` of your Secret `<roksCredentialsSecretName>` (default `roks-ci-credentials`; pipeline namespace, pipeline cluster)

**Running:**

The example PipelineRun lives in `.tekton-examples/` and is not triggered automatically. Its `{{ pull_request_number }}`, `{{ repo_url }}` and `{{ revision }}` placeholders are filled in only by Pipelines-as-Code, so `oc create -f` on the file as it is fails. Either copy it into `.tekton/` on a pull request (Pipelines-as-Code renders and starts it), or replace the placeholders in a copy first (the Pipeline and the Tasks must then already exist in the namespace, see [Deploy Pipeline Resources](#2-deploy-pipeline-resources)):

```bash
sed -e 's/{{ pull_request_number }}/123/g' \
    -e 's|{{ repo_url }}|https://github.com/redhat-sap/sap-edge|g' \
    -e 's/{{ revision }}/<branch or commit>/g' \
    .tekton-examples/roks-eic-ossm3-run.yaml | oc create -f -
tkn pipelinerun logs -f <pipelinerun-name>
```

Cluster name: `redhat-roks-eic-pr<N>` (starts with `redhat-`, at most 30 characters).

**Restricted-resources upload:** right after the run starts it creates the folders `restricted-resources/<clusterName>/elm/` and `restricted-resources/<clusterName>/edge-icell/` in the OBC bucket (earlier zips of both components are moved to `restricted-resources/<clusterName>/archive/`) and waits for the zips in two steps, `wait-elm-zip` and `wait-eic-zip` (tasks, not approvals). Upload the ELM zip to `elm/` first (new-format bundle with `apply-restricted-resources.sh`; the logs of `wait-elm-zip` and `wait-eic-zip` show the upload plan of `prepare-restricted-resources-prefix`: the folders, the console steps and the `aws s3 cp` command); once `apply-rbac-elm` applies it, register the Edge Node with the generated restricted kubeconfig and deploy EIC, then upload the EIC zip to `edge-icell/`. The SAP bundles create all namespaces; the pipeline only adds the mesh labels and SCC annotations: to `edgelm` (plus the mesh control plane) after the ELM zip, before `elm init` starts the ELM pods, and to the EIC namespaces after the EIC zip (`prepare-namespaces-eic`, `configure-mesh-eic`). In ELM, confirm "downloaded and applied" for the ELM resources only after `generate-sa-based-kubeconfig`, and for the EIC resources only after `configure-mesh-eic`, so the pods start with their sidecars. Each task reads only its own component folder under `restricted-resources/<clusterName>/`, never zips directly under `restricted-resources/`. The folders are named after the cluster (unique per run), and each run needs fresh uploads (earlier zips are moved to the run's `archive/` folder; a zip with the same name replaces the archived copy).

#### Browser automation (optional)

With `sapBrowserMode` other than `disabled`, the run starts a Chromium browser in a task pod for the SAP ELM steps (Edge Node, zips, Embedded Cloud Connector, EIC deployment, and the Edge Node deletion at teardown). You reach it through a per-run Route protected by the OpenShift OAuth proxy: only users allowed to create `pods/portforward` in the pipeline namespace get in. The Route is named `sapb-<clusterName>`, and the router host `<route>-<namespace>.<apps domain>` needs a first label (route name + "-" + namespace) of at most 63 characters: with a cluster name of at most 30 characters that leaves room for namespaces of up to 27 characters. A Route the router does not admit ends the session as `failed` with the reason in the log. Default `disabled` (or an empty `sapBrowserImage`): the browser tasks are skipped and everything is done by hand as described above.

**One-time setup** (pipeline namespace):

1. Build and push the runner image as described in [`hack/sap-browser/PIPELINE.md`](../hack/sap-browser/PIPELINE.md#build-and-install-once) (the HCP steps after the push are not needed for ROKS).
2. `oc -n <pipeline namespace> apply -f hack/sap-browser/roks-runner-rbac.yaml`: the ServiceAccount `roks-sap-browser-runner` (reads PipelineRuns/TaskRuns, creates and deletes its Route and Service, gets no Secrets namespace-wide) and the right of the `pipeline` ServiceAccount to create the per-run Role `roks-sap-browser-<cluster>`. That Role grants `get` on this run's three Secrets only, so the `pipeline` ServiceAccount must hold `get` on them itself. If the OAuth proxy logs 403 on `subjectaccessreviews`, bind `system:auth-delegator` to the runner (command in the file).
3. Download the Linux x86_64 `elm` CLI from the SAP Software Download Center and upload it (the binary, a `.zip` or a `.tar.gz`; not a `.SAR`) to `tools/elm/` in the OBC bucket. The browser takes the newest file there. Upload a new one when ELM needs a newer CLI.

Failures before the browser starts (a wrong or unreachable image, or no ServiceAccount because `roks-runner-rbac.yaml` was not applied) fail the browser task's pod and stop the run, unlike failures inside the browser. Try `sapBrowserMode: inspect` first; a rerun reuses the cluster.

**Enable it** in the run file: set `sapBrowserMode` to `inspect` or `auto`, uncomment `sapBrowserImage` (your image) and `sapElmUrl` (the direct ELM URL), and uncomment `taskRunSpecs` (the browser tasks must run as `roks-sap-browser-runner`; without them the browser stops at once with outcome `failed`). An empty `sapBrowserImage` skips the browser tasks, as `disabled` does. `sapBrowserSessionMinutes` (default 180, at most 240) limits each browser session including login, pipeline waits and the hand-over; `sapBrowserLoginMinutes` (default 30) limits the login. The browser does not support a hub cluster: with `hubKubeconfigSecretName` set it stops at once (outcome `skipped-hub`).

**What you do:**

1. After `registry-access`, open the `sap-browser-deploy` log (`tkn pipelinerun logs -f <pipelinerun> -t sap-browser-deploy`) and open the Route link it prints.
2. Log in to OpenShift, then log in to SAP in the browser shown. Playwright continues in that session.
3. After approving `approval-teardown`, do the same with the `sap-browser-teardown` log: a second login, then the Edge Node is deleted. `teardown-roks` runs after it whatever its outcome.

The approvals stay as they are; iFlows are still deployed by hand.

**Outcomes** (result `outcome` of each browser task, e.g. `tkn taskrun describe <taskrun>`): `deployed`, `edge-node-deleted` or `nothing-to-delete` (done); `inspection-finished` (inspect mode); `handed-over` (the automation stopped and you finished by hand); `failed` (setup, login or session failure); `skipped-hub`. The browser step always exits 0, so check the outcome rather than the task status (only pod-level failures, see the one-time setup, fail the task).

**Manual fallback:** whatever happens in the browser, the run continues. On a hand-over the browser stays open with the reason in the log: finish the steps there or in your own browser, then close Chromium or run the `oc exec ... -c step-browser -- node /opt/sap-browser/control.mjs finish` command from the log. Without the browser (`failed`), do the steps by hand: upload the zips to `elm/` and `edge-icell/` (`wait-elm-zip` and `wait-eic-zip` wait for them either way), and at teardown delete the Edge Node in ELM yourself.

**`auto` is not complete yet:** the ELM screens are not mapped, so `auto` hands over to you right after the login. Use `inspect` to record them: after the login Playwright Inspector opens in the browser; record the walkthrough (Add Edge Node, Prerequisites with the ELM zip, Embedded Cloud Connector, Configuration and EIC deployment, the EIC zip, and at teardown the Edge Node deletion), copy the generated code, then resume Inspector. Recordings can contain entered credentials; keep them private. In `inspect` mode nothing is uploaded: files downloaded in the task's browser stay in the pod, so download the zips again in your own browser and upload them to the folders.

**Failed or rejected runs** leave the cluster for debugging (billable): `teardown-roks` is a `finally` task that runs only after `approval-teardown` is approved (then also when `sap-browser-teardown` failed). Clean up with:

```bash
make roks-destroy CLUSTER=redhat-roks-eic-pr123
```

Requires `ibmcloud` CLI (logged in), `container-service` and `vpc-infrastructure` plugins, `jq`, and the same Secrets/env vars as the pipeline.

**Do not push to the PR while `deploy-roks` or `teardown-roks` runs.** The example run sets `cancel-in-progress: "false"` because cancelling kills `terraform apply` (60–90 minutes) or `terraform destroy` (up to 2 hours) mid-way, which can leave a billable cluster that the state does not record and a stale state lock. A push starts a second run instead, which fails on the state lock without changing anything.

**Recovery hints:**

- **Stale state lock**: `Error acquiring the state lock`. Ensure no other run is using the state, then:
  ```bash
  make roks-init CLUSTER=redhat-roks-eic-pr123
  terraform -chdir=roks/terraform force-unlock <lock ID from error>
  ```

- **Cluster created by IBM Cloud but missing from the state** (a run stopped during apply; `ibmcloud ks cluster get --cluster <name>` finds it, `terraform -chdir=roks/terraform state list` has no `ibm_container_vpc_cluster.cluster`): import it, then destroy:
  ```bash
  ibmcloud ks cluster get --cluster redhat-roks-eic-pr123   # note the cluster ID
  make roks-init CLUSTER=redhat-roks-eic-pr123
  terraform -chdir=roks/terraform import -var cluster_name=redhat-roks-eic-pr123 ibm_container_vpc_cluster.cluster <cluster ID>
  make roks-destroy CLUSTER=redhat-roks-eic-pr123
  ```
  Or delete it with `ibmcloud ks cluster rm --cluster redhat-roks-eic-pr123 --force-delete-storage`, wait until `ibmcloud ks cluster get` no longer finds it, then run `make roks-destroy CLUSTER=redhat-roks-eic-pr123` for the rest of the state.

- **Cluster deleted outside Terraform** (provider 2.8.0 fails on 404):
  ```bash
  make roks-init CLUSTER=redhat-roks-eic-pr123
  terraform -chdir=roks/terraform state rm ibm_container_vpc_cluster.cluster
  make roks-destroy CLUSTER=redhat-roks-eic-pr123
  ```

See `roks/terraform/README.md` for details.
