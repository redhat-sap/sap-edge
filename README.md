<!--
SPDX-FileCopyrightText: 2024 SAP edge team
SPDX-FileContributor: Kirill Satarin (@kksat)
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# OCP External Services for SAP EIC Test Validation

This repository provides scripts and procedures for setting up test validation external services for SAP EIC on the OpenShift Container Platform (OCP). The services covered include PostgreSQL and Redis. This guide will help you install and configure these services, as well as perform cleanup after validation.

> **Note:** These services may be optional for a proof of concept (PoC) setup.
> If you don’t enable or configure the external Postgres and Redis during the SAP Edge Integration Cell (EIC) installation, EIC will automatically deploy self-contained Postgres and Redis pods within its own service namespace.

**Important Notice**

Please be aware that this repository is intended **for testing purposes only**. The configurations and scripts provided are designed to assist in test validation scenarios and are not recommended for production use.

**Support Information**

Red Hat does not provide support for the Postgres/Redis services configured through this repository. Support is available directly from the respective vendors:

- **PostgreSQL**: Crunchy Data offers enterprise-level support for their PostgreSQL Operator through a subscription-based model. This includes various tiers with different response times, service levels, bug fixes, security patches, updates, and technical support. A subscription is required for using the software in third-party consulting or support services. For more details, refer to their [Terms of Use](https://www.crunchydata.com/legal/terms-of-use).

- **Redis**: Support for this solution is provided directly by the Redis Labs team, as detailed in [Appendix 1 of the Redis Enterprise Software Subscription Agreement](https://redislabs.com/wp-content/uploads/2019/11/redis-enterprise-software-subscription-agreement.pdf). The agreement categorizes support services into Support Services, Customer Success Services, and Consulting Services, offering assistance from basic troubleshooting to advanced consultancy and ongoing optimization tailored to diverse customer needs.

For comprehensive support, please contact [Crunchy Data](https://www.crunchydata.com/contact) and [Redis Labs](https://redis.io/meeting/) directly.

**Operations**

For operational guidance on Crunchy Postgres and Redis, refer to the official documentation:

- [Redis on Kubernetes](https://redis.io/docs/latest/operate/kubernetes/)
- [Crunchy Postgres Operator Quickstart](https://access.crunchydata.com/documentation/postgres-operator/latest/quickstart)

## Prerequisites

- Access to an OpenShift Container Platform cluster using an account with `cluster-admin` permissions.
- Installed `oc`, `jq`, and `git` command line tools on your local system.

## Shared Storage

When ODF (OpenShift Data Foundation) is installed, set the shared file system parameters as follows:

| Property                     | Settings                        |
|------------------------------|---------------------------------|
| Enable Shared File System    | yes                             |
| Shared File System Storage Class | ocs-storagecluster-cephfs   |

Additionally, set the ODF `ocs-storagecluster-ceph-rbd` storage class as default for RWO/RWX Block volumes to meet most block storage requirements for various services running on OpenShift.

## PostgreSQL

The following steps will install the Crunchy Postgres Operator and use its features to manage the lifecycle of the external PostgreSQL DB service.

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

### Cleanup PostgreSQL

To clean up the PostgresCluster:

```bash
oc delete postgrescluster eic -n sap-eic-external-postgres
bash sap-edge/edge-integration-cell/external-postgres/wait_for_deletion_of_postgrescluster.sh
oc delete subscription crunchy-postgres-operator -n sap-eic-external-postgres
oc get csv -n sap-eic-external-postgres --no-headers | grep 'postgresoperator' | awk '{print $1}' | xargs -I{} oc delete csv {} -n sap-eic-external-postgres
oc delete namespace sap-eic-external-postgres
```

# Redis Setup for SAP EIC on OCP

This guide provides instructions for setting up and validating the Redis service for SAP EIC on OpenShift Container Platform (OCP). The steps include installing the Redis Enterprise Operator, creating a RedisEnterpriseCluster and RedisEnterpriseDatabase, and cleaning up after validation.

## Prerequisites

- Access to an OpenShift Container Platform cluster using an account with `cluster-admin` permissions.
- Installed `oc`, `jq`, and `git` command line tools on your local system.

## Redis Setup

The following steps will install the Redis Enterprise Operator and use its features to manage the lifecycle of the external Redis datastore service.

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
bash sap-edge/edge-integration-cell/get_all_access.sh
```

## Cleanup Redis

To clean up the Redis instance:

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
````

## 🚀 Argo CD GitOps Setup

This project supports automated deployment of external **Postgres** and **Redis** services using **Argo CD** and a GitOps workflow.

**Requirements**
* OpenShift cluster
* OpenShift GitOps Operator
* Access to this Git repository

### 📁 Folder Structure

Argo CD uses an **App of Apps** model located in:

edge-integration-cell/argocd-apps/


This folder defines four Argo CD Applications:

| Application Name             | Purpose                            | Sync Wave |
|-----------------------------|------------------------------------|-----------|
| `postgres-operator`         | Installs Crunchy Postgres Operator | 0         |
| `external-postgres`         | Deploys PostgresCluster CR         | 1         |
| `external-redis-operator`   | Installs Redis Enterprise Operator | 0         |
| `external-redis`            | Deploys RedisCluster CRs           | 1         |

Each application includes a **sync wave annotation** to ensure the operator is deployed before its related custom resources.

---

### 🔧 Deploying with Argo CD

1. Make sure Argo CD is installed in your cluster (e.g., via 'Red Hat OpenShift GitOps' Operator).
2. Create a **parent Argo CD Application** pointing to the `argocd-apps` folder:

```bash
oc apply -f sap-edge/edge-integration-cell/sap-eic-external-services-app.yaml
```

3. Apply the [Security Context Constraint (SCC)](https://redis.io/docs/latest/operate/kubernetes/deployment/openshift/openshift-cli/#install-security-context-constraint) for the redis deployment:
   - For OpenShift versions 4.16 and later, use
    ```bash
    oc apply -f sap-edge/edge-integration-cell/redis-operator/security_context_constraint_v2.yaml
    ```
   - For OpenShift versions earlier than 4.16, use:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/redis-operator/security_context_constraint.yaml
    ```
4. The Argo CD Application Controller requires administrative privileges to manage custom resources (CRs) in the `sap-eic-external-postgres` and `sap-eic-external-redis` namespaces. Grant these privileges by applying the provided RBAC role bindings:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/argocd-rbac/argocd-admin-rolebinding-postgres.yaml
    oc apply -f sap-edge/edge-integration-cell/argocd-rbac/argocd-admin-rolebinding-redis.yaml
    ```
5. Argo CD will:
* Install the Postgres and Redis operators
* Wait for them to be ready
* Deploy the respective PostgresCluster and RedisEnterpriseCluster, RedisDB custom resources

### Running Cluster-Specific Endpoint Tests

You can run endpoint tests in two ways:

#### Option 1: CI/CD via Tekton

1. Copy the pipeline template:

   ```bash
   cp .tekton-templates/pr-endpoint-run.yaml .tekton/pr-endpoint-run.yaml
   ```

2. Edit the following fields in the copied file:
   - `host`: The full hostname of the SAP EIC endpoint to test.
   - `authSecret`: Authentication secret (example command below for creating the secret)
   - `ingressIP`: External ingress IP of the cluster
   - `publicDNS`: Whether using public DNS for resolution. For external hosts.

   Example to create the auth secret:

   ```bash
   oc create secret generic endpoint-auth \
     --type=Opaque \
     --from-literal=auth_key="QW5RPQ=="
   ```

3. Commit and push the changes — the pipeline will trigger automatically on your PR.

#### Option 2: Run Locally

To run the same tests locally (outside the CI/CD pipeline), set the required environment variables and execute the `make test-endpoint` command:

```bash
export CLUSTER_NAME=<your-cluster-name>
export AUTH_KEY=<your-auth-key>
export INGRESS_IP=<your-ingress-ip>

make test-endpoint
```

**Environment Variables:**

* CLUSTER_NAME: Name of the target cluster
* AUTH_KEY: Authentication key (as used in the Tekton secret)
* INGRESS_IP: External ingress IP of the cluster

_**Note**: Ensure your test script is configured to read these environment variables. If not, some modifications may be necessary._

# License

This project is licensed under the Apache License 2.0. See the [LICENSE](https://www.apache.org/licenses/LICENSE-2.0) for details.
