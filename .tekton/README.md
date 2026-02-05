<!--
SPDX-FileCopyrightText: 2024 SAP edge team
SPDX-License-Identifier: Apache-2.0
-->

# Tekton Pipelines

This directory contains Tekton CI/CD pipeline definitions for SAP Edge Integration Cell deployment and testing.

## Pipelines

### 1. ARO Endpoint Test Pipeline (`pipelines/aro-endpoint-test-pipeline.yaml`)
**Purpose**: Full ARO deployment → endpoint testing → cleanup workflow

**Workflow**:
1. Deploy ARO cluster with Azure services (PostgreSQL/Redis)
2. Validate deployment and get cluster access
3. **Manual approval** for testing
4. Run comprehensive endpoint tests
5. **Manual approval** for teardown
6. Clean up all resources

**Use case**: Automated testing and validation of EIC endpoints on fresh ARO clusters

### 2. ARO Quay Deployment Pipeline (`pipelines/aro-quay-deployment-pipeline.yaml`)
**Purpose**: ARO deployment → Quay registry → edgelm validation workflow

**Workflow**:
1. Deploy ARO cluster only (no Azure PostgreSQL/Redis services)
2. Validate deployment and get cluster access
3. Deploy Quay registry with Azure storage and certificate trust
4. **Manual approval** after ARO and Quay deployment
5. Check edgelm namespace pod status (running/completed)
6. Generate comprehensive status report
7. **Final manual approval** for pipeline completion

**Use case**: Production-ready ARO + Quay deployment for container registry needs (without external databases)

### 3. Endpoint Test Pipeline (`pipelines/endpoint-test-pipeline.yaml`)
**Purpose**: Standalone endpoint testing for existing clusters

**Use case**: Testing EIC endpoints on already deployed clusters

## Tasks

### Core Deployment Tasks
- `aro-deploy-with-eic-services`: Deploy ARO cluster with EIC services (PostgreSQL and Redis) using Bicep templates
- `aro-deploy-only`: Deploy ARO cluster only (without PostgreSQL and Redis) using Bicep templates
- `aro-validate-and-get-access`: Validate ARO deployment and configure access
- `aro-teardown`: Clean up ARO cluster and resources

### Quay Registry Tasks
- `aro-quay-deploy`: Deploy Quay registry with Azure storage
- `aro-deployment-status-report`: Validate pods and generate deployment reports (ARO)
- `rosa-deployment-status-report`: Validate pods and generate deployment reports (ROSA)

### Testing Tasks
- `endpoint-tests`: Test EIC API endpoints
- `rate-limit-test`: Validate API rate limiting
- `jira-add-comment-custom`: Update Jira tickets with results

## Pipeline Runs

### ARO Quay Deployment Run (`aro-quay-deployment-run.yaml`)
Example PipelineRun for the ARO + Quay deployment pipeline.

**Required Parameters**:
- `aroClusterName`: Name of the ARO cluster (e.g., "sapeic")
- `aroLocation`: Azure region (default: "northeurope")
- `aroVersion`: OpenShift version (default: "4.17.27")
- `repoUrl`: Git repository URL
- `revision`: Git branch/tag (default: "main")

**Required Secrets**:
- `azure-sp-secret`: Azure service principal credentials
- `redhat-pull-secret`: Red Hat container registry auth
- `azure-postgres-admin-password`: PostgreSQL admin password
- `quay-admin-secret`: Quay admin credentials (password, email)
- `jira-secret`: Jira API credentials (optional)

## Usage

### 1. Create Required Secrets
```bash
# Azure service principal secret
oc create secret generic azure-sp-secret \
  --from-literal=CLIENT_ID="your-client-id" \
  --from-literal=CLIENT_SECRET="your-client-secret" \
  --from-literal=TENANT_ID="your-tenant-id" \
  --from-literal=ARO_RESOURCE_GROUP="aro-sapeic" \
  --from-literal=ARO_DOMAIN="saponrhel.org"

# Red Hat pull secret
oc create secret generic redhat-pull-secret \
  --from-literal=PULL_SECRET='{"auths":{"registry.redhat.io":{"auth":"..."}}}'

# PostgreSQL admin password (only needed for endpoint testing pipeline)
oc create secret generic azure-postgres-admin-password \
  --from-literal=POSTGRES_ADMIN_PASSWORD="your-secure-password"

# Quay admin credentials (for Quay deployment pipeline)
oc create secret generic quay-admin-secret \
  --from-literal=password="quay-admin-password" \
  --from-literal=email="admin@sap.com"

# ROSA-specific secrets
# AWS credentials
oc create secret generic aws-credentials-secret \
  --from-literal=AWS_ACCESS_KEY_ID="your-access-key" \
  --from-literal=AWS_SECRET_ACCESS_KEY="your-secret-key"

# Red Hat OCM token
oc create secret generic redhat-token-secret \
  --from-literal=REDHAT_OCM_TOKEN="your-ocm-token"

# PostgreSQL admin password for ROSA (RDS)
# ⚠️ IMPORTANT: AWS RDS PostgreSQL does NOT allow these characters: / @ " (space)
# Use only: letters, numbers, and these special characters: ! # $ % & ( ) * + , - . : ; < = > ? [ \ ] ^ _ ` { | } ~
oc create secret generic rosa-postgres-admin-password \
  --from-literal=POSTGRES_ADMIN_PASSWORD="YourSecure-Password123!"

# EIC authentication secret
oc create secret generic eic-auth-secret \
  --from-literal=username="eic-user" \
  --from-literal=password="eic-password"
```

### 2. Deploy Pipeline Resources
```bash
# Apply all pipeline and task definitions
oc apply -f .tekton/tasks/
oc apply -f .tekton/pipelines/
```

### 3. Run ARO + Quay Deployment Pipeline
```bash
# Update parameters in aro-quay-deployment-run.yaml
# Then apply:
oc apply -f .tekton/aro-quay-deployment-run.yaml

# Monitor pipeline
tkn pipelinerun logs aro-quay-deployment-run -f

# Check status
tkn pipelinerun list
```

### 4. Manual Approvals
The ARO Quay deployment pipeline includes two manual approval gates:

1. **Post-deployment approval**: After ARO and Quay are deployed
2. **Final approval**: After edgelm validation and status reporting

To approve manually:
```bash
# List pending approvals
oc get approvaltasks

# Approve a task
oc patch approvaltask <approval-task-name> --type=merge -p '{"spec":{"approved":true}}'
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
