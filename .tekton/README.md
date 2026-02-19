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

### 2. Deploy Pipeline Resources
```bash
oc apply -f .tekton/tasks/
oc apply -f .tekton/pipelines/
```

### 3. Run a Pipeline
```bash
# Apply a PipelineRun
oc apply -f .tekton/<pipeline-run>.yaml

# Monitor
tkn pipelinerun logs <pipelinerun-name> -f
tkn pipelinerun list
```

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

## Troubleshooting

### Common Issues
1. **Task timeouts**: Check individual task logs for specific failures
2. **Secret not found**: Verify all required secrets are created
3. **Azure authentication**: Check service principal permissions 
4. **Quay deployment fails**: Verify Azure storage account creation
5. **Pod status check fails**: Check if edgelm namespace exists

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
