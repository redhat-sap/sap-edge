# OCP External Services for SAP EIC Validation

This repository provides scripts and procedures for setting up and validating external services for SAP EIC on OpenShift Container Platform (OCP). The services covered include PostgreSQL and Redis. This guide will help you install and configure these services, as well as perform cleanup after validation.

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
    oc apply -f sap-edge/edge-integration-cell/external-postgres/operatorgroup.yaml
    ```
4. Apply the Subscription configuration:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-postgres/subscription.yaml
    ```
5. Wait for the Postgres operator to be ready:
    ```bash
    bash sap-edge/edge-integration-cell/external-postgres/wait_for_postgres_operator_ready.sh
    ```
6. Create a PostgresCluster:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-postgres/postgrescluster-v14.yaml
    ```
    - For other versions, replace `v14` with `v15` or `v16`.
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
    oc apply -f sap-edge/edge-integration-cell/external-redis/operatorgroup.yaml
    ```
4. Apply the Subscription configuration:
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-redis/subscription.yaml
    ```
5. Apply the Security Context Constraint (SCC):
    ```bash
    oc apply -f sap-edge/edge-integration-cell/external-redis/security_context_constraint.yaml
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
- External Redis Server Name: `[leave me blank]`

## Cleanup Redis

To clean up the Redis instance:

```bash
oc delete redisenterprisedatabase redb -n sap-eic-external-redis
oc delete redisenterprisecluster rec -n sap-eic-external-redis
bash sap-edge/edge-integration-cell/external-redis/wait_for_deletion_of_rec.sh
oc delete subscription redis-enterprise-operator-cert -n sap-eic-external-redis
oc get csv -n sap-eic-external-redis --no-headers | grep 'redis-enterprise-operator' | awk '{print $1}' | xargs -I{} oc delete csv {} -n sap-eic-external-redis
oc delete scc redis-enterprise-scc-v2
oc delete namespace sap-eic-external-redis
````

# License

This project is licensed under the Apache License 2.0. See the [LICENSE](https://www.apache.org/licenses/LICENSE-2.0) for details.