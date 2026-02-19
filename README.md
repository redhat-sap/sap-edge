<!--
SPDX-FileCopyrightText: 2024 SAP edge team
SPDX-FileContributor: Kirill Satarin (@kksat)
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# SAP Edge Integration Cell (EIC) - External Services

> [!IMPORTANT]
> **Support Disclaimer:** Red Hat does not provide support for the PostgreSQL/Redis/Valkey services configured through this repository. Support is available directly from the respective vendors:
> - **PostgreSQL**: [Crunchy Data](https://www.crunchydata.com/contact)
> - **Redis**: [Redis Labs](https://redis.io/meeting/)
> - **Valkey**: [Valkey.io](https://valkey.io/) (community-supported)
>
> This repository is intended for **testing purposes only**. The configurations and scripts are designed for test validation scenarios and are not recommended for production use.

This repository provides tooling for deploying external services (PostgreSQL, Redis, Valkey) for SAP Edge Integration Cell (EIC) on OpenShift Container Platform.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [External Services Setup](#external-services-setup)
  - [Databases](#databases)
    - [PostgreSQL](#postgresql)
  - [Datastores](#datastores)
    - [Redis](#redis)
    - [Valkey](#valkey)
- [GitOps with Argo CD](#gitops-with-argo-cd)
- [Automated Deployment Scripts](#automated-deployment-scripts)
- [Operations Documentation](#operations-documentation)
- [License](#license)

> For CI/CD pipeline documentation, see [.tekton/README.md](.tekton/README.md)

## Overview

This repository provides scripts and procedures for setting up test validation external services for SAP EIC on the OpenShift Container Platform (OCP). The services covered include:

**Databases:**
- **PostgreSQL** (via Crunchy Data Operator)

**Datastores:**
- **Redis** (via Redis Enterprise Operator)
- **Valkey** (via Red Hat Helm Charts)

> **Note:** These services are optional. If you don't enable or configure external database/datastore during the SAP EIC installation, EIC will automatically deploy self-contained pods within its own service namespace.

## Prerequisites

- Access to an OpenShift Container Platform cluster using an account with `cluster-admin` permissions
- Installed command line tools: `oc`, `jq`, `git`
- For GitOps: OpenShift GitOps Operator installed

## Shared Storage

When ODF (OpenShift Data Foundation) is installed, set the shared file system parameters as follows:

| Property                     | Settings                        |
|------------------------------|---------------------------------|
| Enable Shared File System    | yes                             |
| Shared File System Storage Class | ocs-storagecluster-cephfs   |

Additionally, set the ODF `ocs-storagecluster-ceph-rbd` storage class as default for RWO/RWX Block volumes to meet most block storage requirements for various services running on OpenShift.

# External Services Setup

## Databases

### PostgreSQL

The following steps install the Crunchy Postgres Operator and deploy an external PostgreSQL DB service.

1. Clone the repository:
    ```bash
    git clone https://github.com/redhat-sap/sap-edge.git
    ```
2. Create a new project:
    ```bash
    oc new-project sap-eic-external-postgres
    ```
3. Apply the OperatorGroup configuration:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/postgres-operator/operatorgroup.yaml
    ```
4. Apply the Subscription configuration:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/postgres-operator/subscription.yaml
    ```
5. Wait for the Postgres operator to be ready:
    ```bash
    bash sap-edge/edge-integration-cell/external-postgres/wait_for_postgres_operator_ready.sh
    ```
6. Create a PostgresCluster:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-postgres/postgrescluster-v15.yaml
    ```
    - For other versions, replace `v15` with `v16` or `v17`.
7. Wait for Crunchy Postgres to be ready:
    ```bash
    bash sap-edge/edge-integration-cell/external-postgres/wait_for_postgres_ready.sh
    ```
8. Get access details of Crunchy Postgres:
    ```bash
    bash sap-edge/edge-integration-cell/external-postgres/get_external_postgres_access.sh
    ```

After running the above script, you will get the access details of Crunchy Postgres like the following:
- External DB Hostname: `hippo-primary.sap-eic-external-postgres.svc`
- External DB Port: `5432`
- External DB Name: `eic`
- External DB Username: `eic`
- External DB Password: `xklaieniej12#`
- External DB TLS Root Certificate saved to `external_postgres_db_tls_root_cert.crt`

Please use the provided information to set up the EIC external DB accordingly.

#### Cleanup PostgreSQL

##### Option 1: Automated Cleanup (Recommended)

Use the provided cleanup script for comprehensive automated cleanup:

```bash
# Interactive cleanup with confirmation
bash sap-edge/edge-integration-cell/cleanup_postgres.sh

# Force cleanup without prompts (for CI/CD)
bash sap-edge/edge-integration-cell/cleanup_postgres.sh --force

# Dry-run to preview what would be deleted
bash sap-edge/edge-integration-cell/cleanup_postgres.sh --dry-run

# Custom namespace cleanup
bash sap-edge/edge-integration-cell/cleanup_postgres.sh --namespace my-postgres-namespace
```

##### Option 2: Manual Cleanup

To manually clean up the PostgresCluster:

```bash
oc delete postgrescluster eic -n sap-eic-external-postgres
bash sap-edge/edge-integration-cell/external-postgres/wait_for_deletion_of_postgrescluster.sh
oc delete subscription crunchy-postgres-operator -n sap-eic-external-postgres
oc get csv -n sap-eic-external-postgres --no-headers | grep 'postgresoperator' | awk '{print $1}' | xargs -I{} oc delete csv {} -n sap-eic-external-postgres
oc delete namespace sap-eic-external-postgres
```

## Datastores

### Redis

The following steps install the Redis Enterprise Operator and deploy an external Redis datastore service.

1. Clone the repository:
    ```bash
    git clone https://github.com/redhat-sap/sap-edge.git
    ```
2. Create a new project:
    ```bash
    oc new-project sap-eic-external-redis
    ```
3. Apply the OperatorGroup configuration:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/redis-operator/operatorgroup.yaml
    ```
4. Apply the Subscription configuration:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/redis-operator/subscription.yaml
    ```
5. Apply the [Security Context Constraint (SCC)](https://redis.io/docs/latest/operate/kubernetes/deployment/openshift/openshift-cli/#install-security-context-constraint):
   - For OpenShift versions 4.16 and later, use
    ```bash
    oc apply -f sap-edge/edge-integration-cell/redis-operator/security_context_constraint_v2.yaml
    ```
   - For OpenShift versions earlier than 4.16, use:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/redis-operator/security_context_constraint.yaml
    ```
6. Wait for the Redis operator to be ready:
    ```bash
    bash sap-edge/edge-integration-cell/external-redis/wait_for_redis_operator_ready.sh
    ```
7. Create a RedisEnterpriseCluster:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-redis/redis_enterprise_cluster.yaml
    ```
8. Wait for the RedisEnterpriseCluster to be ready:
    ```bash
    bash sap-edge/edge-integration-cell/external-redis/wait_for_rec_running_state.sh
    ```
9. Create a RedisEnterpriseDatabase:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-redis/redis_enterprise_database.yaml
    ```
    - Note: You might need to run the above command several times until it works because the previously created RedisEnterpriseCluster needs some time to enable the admission webhook successfully.
10. Wait for the RedisEnterpriseDatabase to be ready:
    ```bash
    bash sap-edge/edge-integration-cell/external-redis/wait_for_redb_active_status.sh
    ```
11. Get access details of Redis:
    ```bash
    bash sap-edge/edge-integration-cell/external-redis/get_redis_access.sh
    ```

After running the above script, you will get the access details of Redis like the following:
- External Redis Addresses: `redb-headless.sap-eic-external-redis.svc:12117`
- External Redis Mode: `standalone`
- External Redis Username: `[leave me blank]`
- External Redis Password: `XpglWqoR`
- External Redis Sentinel Username: `[leave me blank]`
- External Redis Sentinel Password: `[leave me blank]`
- External Redis TLS Certificate content saved to `external_redis_tls_certificate.pem`
- External Redis Server Name: `rec.sap-eic-external-redis.svc.cluster.local`

Alternatively, you can run the following script to retrieve access details for both Redis and Postgres:
```bash
bash sap-edge/edge-integration-cell/get_all_accesses.sh
```

#### Cleanup Redis

**Option 1: Automated Cleanup**

Use the provided cleanup script for comprehensive automated cleanup:

```bash
# Interactive cleanup with confirmation (auto-detects OpenShift version)
bash sap-edge/edge-integration-cell/cleanup_redis.sh

# Force cleanup without prompts (for CI/CD)
bash sap-edge/edge-integration-cell/cleanup_redis.sh --force

# Dry-run to preview what would be deleted
bash sap-edge/edge-integration-cell/cleanup_redis.sh --dry-run

# Specify OpenShift version for SCC cleanup
bash sap-edge/edge-integration-cell/cleanup_redis.sh --ocp-version 4.16

# Custom namespace cleanup
bash sap-edge/edge-integration-cell/cleanup_redis.sh --namespace my-redis-namespace
```

**Option 2: Manual Cleanup**

To manually clean up the Redis instance:

```bash
oc delete redisenterprisedatabase redb -n sap-eic-external-redis
oc delete redisenterprisecluster rec -n sap-eic-external-redis
bash sap-edge/edge-integration-cell/external-redis/wait_for_deletion_of_rec.sh
oc delete subscription redis-enterprise-operator-cert -n sap-eic-external-redis
oc get csv -n sap-eic-external-redis --no-headers | grep 'redis-enterprise-operator' | awk '{print $1}' | xargs -I{} oc delete csv {} -n sap-eic-external-redis
# For OpenShift versions earlier than 4.16
oc delete scc redis-enterprise-scc-v2
# For OpenShift versions 4.16 and later
oc delete scc redis-enterprise-scc
oc delete namespace sap-eic-external-redis
```

### Valkey

Valkey is a Redis-compatible in-memory datastore. For SAP EIC, TLS is always enabled.

For detailed deployment instructions, see [edge-integration-cell/external-valkey/README.md](edge-integration-cell/external-valkey/README.md).

#### Quick Start

```bash
cd edge-integration-cell/external-valkey

# Deploy Valkey with TLS
bash deploy_valkey.sh --password <your-password>

# Get access details for SAP EIC configuration
bash get_valkey_access.sh

# Cleanup
bash cleanup_valkey.sh
```

## GitOps with Argo CD

This project supports automated deployment using Argo CD and a GitOps workflow.

**Requirements:** OpenShift cluster with OpenShift GitOps Operator installed.

### Deploying with Argo CD

1. Apply the parent Argo CD Application:
   ```bash
   oc apply -f edge-integration-cell/sap-eic-external-services-app.yaml
   ```

2. Apply the Security Context Constraint for Redis:
   ```bash
   # OpenShift 4.16+
   oc apply -f edge-integration-cell/redis-operator/security_context_constraint_v2.yaml
   # OpenShift < 4.16
   oc apply -f edge-integration-cell/redis-operator/security_context_constraint.yaml
   ```

3. Grant Argo CD admin privileges:
   ```bash
   oc apply -f edge-integration-cell/argocd-rbac/argocd-admin-rolebinding-postgres.yaml
   oc apply -f edge-integration-cell/argocd-rbac/argocd-admin-rolebinding-redis.yaml
   ```

Argo CD will install the operators and deploy the PostgresCluster and RedisEnterpriseCluster resources.

## Automated Deployment Scripts

For convenience, automated deployment scripts are available that simplify the manual steps into single commands.

### Deploy All Services

```bash
# Interactive deployment
bash edge-integration-cell/deploy_all_external_services.sh

# Force mode (no prompts)
bash edge-integration-cell/deploy_all_external_services.sh --force

# Dry-run to preview
bash edge-integration-cell/deploy_all_external_services.sh --dry-run
```

### Deploy Individual Services

```bash
# PostgreSQL only
bash edge-integration-cell/deploy_postgres.sh
bash edge-integration-cell/deploy_postgres.sh --version v16

# Redis only
bash edge-integration-cell/deploy_redis.sh
bash edge-integration-cell/deploy_redis.sh --type ha
```

### Cleanup All Services

```bash
# Interactive cleanup
bash edge-integration-cell/cleanup_all_external_services.sh

# Force cleanup
bash edge-integration-cell/cleanup_all_external_services.sh --force
```

## Operations Documentation

- [Crunchy Postgres Operator Quickstart](https://access.crunchydata.com/documentation/postgres-operator/latest/quickstart)
- [Redis on Kubernetes](https://redis.io/docs/latest/operate/kubernetes/)
- [Valkey Documentation](https://valkey.io/docs/)

# License

This project is licensed under the Apache License 2.0. See the [LICENSE](https://www.apache.org/licenses/LICENSE-2.0) for details.