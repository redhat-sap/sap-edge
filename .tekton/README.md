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

### HCP Tasks
- `hcp-create-hosted-cluster-task`: Create HCP cluster
- `hcp-wait-cluster-ready-task`: Wait for cluster readiness
- `hcp-deploy-postgres-task`, `hcp-deploy-redis-task`: Deploy external services
- `hcp-get-all-accesses-task`: Retrieve service credentials
- `hcp-validate-and-create-configmap-task`: Validate and configure
- `hcp-teardown-task`: Clean up resources

### OSSM3 Tasks
- `ossm3-verify-operators-task`: Verify Service Mesh 3.x operators are installed
- `ossm3-prepare-namespaces-task`: Create and configure namespaces with labels and SCC annotations
- `ossm3-configure-mesh-task`: Deploy IstioCNI and Istio control plane
- `ossm3-apply-rbac-task`: Apply RBAC permissions from SAP Note 3618713 resources
- `ossm3-generate-sa-based-kubeconfig-task`: Generate SA-based restricted kubeconfig for ELM registration

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

Requirements: `oc`, Python 3.11 or newer, and cluster-admin access. Log in to the
target cluster first; the script uses the current context and honors `KUBECONFIG`.
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
