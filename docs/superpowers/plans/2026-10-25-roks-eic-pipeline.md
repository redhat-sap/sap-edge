<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# ROKS EIC Validation Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `roks-eic-full-test-pipeline` that provisions a ROKS (Red Hat OpenShift on IBM Cloud, VPC) cluster per PR with Terraform, prepares it for SAP ELM like the ROSA pipeline, runs the EIC endpoint tests, and destroys it.

**Architecture:** `roks/terraform/` (IBM-Cloud/ibm provider, COS-backed `s3` state) creates VPC, cluster and optional services. Five new Tekton tasks (`roks-deploy`, `roks-validate-and-get-access`, `roks-validate-and-create-configmap`, `roks-quay-deploy`, `roks-teardown`) mirror their ROSA counterparts; every cloud-agnostic task is reused unchanged via the workspace `kubeconfig`. Tested locally with `terraform validate`, tfsec/checkov/tflint and the `hack/tekton-tests/` harness (stubbed `terraform`/`ibmcloud`/`oc`).

**Tech Stack:** Terraform ≥ 1.10, IBM-Cloud/ibm provider, IBM Cloud CLI + `container-service` plugin, Tekton v1 / OpenShift Pipelines (PaC), bash 5 (UBI9), Python 3 harness.

**Spec:** `docs/superpowers/specs/2026-10-25-roks-eic-pipeline-design.md`

## Global Constraints

- Region `eu-de`; resource group `redhat-sap-edge-roks-ci`; nothing outside that resource group is created, modified or deleted.
- Every IBM resource the pipeline creates is named with prefix `redhat-` and tagged `owner:redhat`, `project:sap-edge`, `pr:<N>`; cluster name `redhat-roks-eic-pr{{ pull_request_number }}`.
- No OpenShift entitlement (regular license); workers `bx2.16x64`, 1 per zone across 3 zones (`eu-de-1`, `eu-de-2`, `eu-de-3`); OpenShift version from a param (default `4.21_openshift`).
- VPC address prefixes inside `10.0.0.0/16`; ROKS `pod_subnet` `10.128.0.0/14`; service subnet left at the ROKS default.
- Terraform state: COS bucket via `s3` backend, key `roks/<cluster>/terraform.tfstate`, `use_lockfile = true`; Terraform ≥ 1.10 installed at runtime in tasks.
- Credentials: Secret `roksIbmcloudSecretName` key `IBMCLOUD_API_KEY`; Secret `terraformStateSecretName` keys `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (COS HMAC). Never echo secrets, never put them in results or approval descriptions.
- Shared tasks are reused unchanged and fed by the workspace file `$(workspaces.source.path)/kubeconfig` (`useWorkspaceKubeconfig: "true"`), wired like `rosa-eic-full-test-pipeline`.
- ApprovalTasks carry no `when`; no `finally` teardown (failed runs keep the cluster; `make roks-destroy CLUSTER=<name>` cleans up). `skipEicValidation` is dropped; `skipAutomatedTests` kept.
- Run file lives in `.tekton-examples/` (on-demand, not every PR).
- Embedded scripts `#!/usr/bin/env bash` + `set -euo pipefail`, shellcheck-clean at default severity; SPDX headers on every new file; `npm run cspell` clean (new words → `.config/cspell-words.txt`); CI `make lint` (tflint, tfsec, checkov, shellcheck, reuse, cspell) must pass for the new Terraform; commits signed off (`git commit -s`).

## Review Focus

- Teardown after a partial apply (cluster create failed half way, VPC/COS exist): destroy must still remove what state tracks and exit cleanly (Task 6 test `destroy_partial_state`).
- Re-run on the same PR (state and cluster already exist): deploy reuses the same state key and does not create a second cluster (Task 3 test `rerun_same_state_key`).
- Secrets leaking into logs: the IBM API key, HMAC keys and Postgres password must not appear in task output (Task 3 and Task 6 tests `no_secret_in_output`).
- Teardown sweep scope: leftover load balancers/volumes are only deleted inside `redhat-sap-edge-roks-ci` and only when tagged for this cluster (Task 6 test `sweep_scoped_to_group_and_cluster`).
- Invalid cluster names (too long, uppercase) fail early with a clear message instead of an opaque IBM API error (Task 1 variable validation + Task 3 test `invalid_cluster_name_fails`).

---

## File Structure

| Path | Responsibility |
|---|---|
| `roks/terraform/provider.tf` | Terraform/provider versions, `s3` backend (COS), `ibm` provider |
| `roks/terraform/variables.tf` | Inputs with validation |
| `roks/terraform/network.tf` | VPC, address prefixes, subnets, public gateways |
| `roks/terraform/cluster.tf` | COS instance for the cluster, `ibm_container_vpc_cluster`, admin kubeconfig data source |
| `roks/terraform/services.tf` | Optional IBM Cloud Databases (PostgreSQL, Redis), optional Quay COS bucket + HMAC key |
| `roks/terraform/outputs.tf` | Outputs consumed by the tasks |
| `roks/terraform/terraform.tfvars.example`, `roks/terraform/README.md` | Local usage |
| `roks.makefile` (+ `include` in `Makefile`) | Local init/plan/apply/destroy, `roks-destroy`, ROKS lint targets wired into `make lint` |
| `.tekton/tasks/roks-*-task.yaml` | Five ROKS tasks |
| `.tekton/pipelines/roks-eic-full-test-pipeline.yaml` | Pipeline |
| `.tekton-examples/roks-eic-ossm3-run.yaml` | Example PipelineRun |
| `hack/tekton-tests/test_roks_*.sh` | Harness tests for the ROKS tasks |

---

### Task 1: Terraform — network, cluster, outputs, state backend, lint wiring

**Files:**
- Create: `roks/terraform/provider.tf`, `variables.tf`, `network.tf`, `cluster.tf`, `outputs.tf`, `terraform.tfvars.example`, `README.md`, `roks.makefile`
- Modify: `Makefile` (include `roks.makefile`; add `roks-tflint roks-tfsec roks-checkov` to `lint`), `.gitignore` (ignore `roks/terraform/.terraform`, `terraform.tfvars`, `backend.config`, `.terraform.lock.hcl`, mirroring the `rosa/terraform` lines)

**Interfaces:**
- Produces (variables): `cluster_name` (string, validation: `^[a-z][a-z0-9-]{0,30}[a-z0-9]$`, ≤ 32 chars), `region` (default `eu-de`), `resource_group` (default `redhat-sap-edge-roks-ci`), `openshift_version` (default `4.21_openshift`), `worker_flavor` (default `bx2.16x64`), `workers_per_zone` (number, default 1), `zones` (list, default `["eu-de-1","eu-de-2","eu-de-3"]`), `pr_number` (string, default `""`), `kubeconfig_dir` (string, default `"./.kube"`), `deploy_postgres` / `deploy_redis` / `deploy_quay_storage` (bool, default false, used in Task 2), `postgres_admin_password` (sensitive, default `""`, Task 2).
- Produces (outputs): `cluster_id`, `cluster_name`, `ingress_hostname`, `resource_group_id`, `admin_kubeconfig_path` (file written by `data "ibm_container_cluster_config" "admin"` with `admin = true`, `config_dir = var.kubeconfig_dir`), `vpc_id`.
- Produces (backend): `backend "s3" {}` partial config; tasks pass `bucket`, `key`, `region` (`eu-de`), `endpoints = { s3 = <COS endpoint> }`, `use_lockfile = true`, `skip_credentials_validation`, `skip_region_validation`, `skip_requesting_account_id`, `skip_s3_checksum`, `use_path_style = true` via `-backend-config`.
- Produces (make): `roks-init`, `roks-plan`, `roks-apply`, `roks-destroy` (`CLUSTER=<name>` required; uses the same state key `roks/$(CLUSTER)/terraform.tfstate`), `roks-tflint`, `roks-tfsec`, `roks-checkov`.

- [ ] **Step 1: Write the failing check** — `make roks-tflint roks-tfsec roks-checkov` and `cd roks/terraform && terraform init -backend=false && terraform validate` → Expected: FAIL (no `roks/terraform`).
- [ ] **Step 2: Implement** the files per Interfaces. Network: one `ibm_is_vpc` (`address_prefix_management = "manual"`), one `ibm_is_vpc_address_prefix` per zone (`10.0.0.0/18`, `10.0.64.0/18`, `10.0.128.0/18`), one `/20` subnet per zone inside its prefix, one public gateway per zone attached to its subnet. Cluster: `ibm_resource_instance` COS (`cloud-object-storage`, plan `standard`, location `global`), `ibm_container_vpc_cluster` (`kube_version = var.openshift_version`, `flavor`, `worker_count = var.workers_per_zone`, one `zones` block per zone, `cos_instance_crn`, `pod_subnet = "10.128.0.0/14"`, `disable_public_service_endpoint = false`, `wait_till = "IngressReady"`, `entitlement` unset). Names: `redhat-${var.cluster_name}-<kind>`; tags: `owner:redhat`, `project:sap-edge`, and `pr:${var.pr_number}` when set. Pin provider `IBM-Cloud/ibm` to a current `~>` minor and `required_version = ">= 1.10"`. tfsec/checkov findings that are inherent to an ephemeral test cluster get inline `#checkov:skip=…:<reason>` / `#tfsec:ignore:…` with a reason, as in `rosa/terraform/aws-services.tf`. If `tflint` is missing locally, `brew install tflint` is allowed.
- [ ] **Step 3: Verify** — `terraform fmt -check -recursive roks/terraform`, `terraform validate` (after `init -backend=false`), `make roks-tflint roks-tfsec roks-checkov` → all clean; `.venv/bin/reuse lint`; `npm run cspell` clean.
- [ ] **Step 4: Commit** — `git commit -s -m "feat(roks): terraform for ROKS VPC cluster with COS state backend"`

---

### Task 2: Terraform — optional managed services (PostgreSQL, Redis, Quay storage)

**Files:**
- Create: `roks/terraform/services.tf`
- Modify: `roks/terraform/outputs.tf`, `roks/terraform/terraform.tfvars.example`, `roks/terraform/README.md`

**Interfaces:**
- Consumes: Task 1 variables `deploy_postgres`, `deploy_redis`, `deploy_quay_storage`, `postgres_admin_password`, names/tags/resource group.
- Produces (outputs, `null` when disabled): `postgres_host`, `postgres_port`, `postgres_database` (`edgedb`), `redis_host`, `redis_port`, `quay_cos_bucket`, `quay_cos_endpoint` (regional private/public S3 endpoint for `eu-de`), `quay_hmac_access_key_id` (sensitive), `quay_hmac_secret_access_key` (sensitive), `redis_password` (sensitive).

- [ ] **Step 1: Write the failing check** — add to `roks/terraform/README.md` a "Validate" section; run `terraform validate` with a scratch tfvars that sets all three flags `true` (use `terraform console`-free validation: `terraform validate` plus `grep` that `outputs.tf` declares each output name above) → Expected: FAIL (outputs missing).
- [ ] **Step 2: Implement** with `count`/`for_each` gated by the flags: `ibm_database` PostgreSQL (`databases-for-postgresql`) and Redis (`databases-for-redis`) in `eu-de`, smallest supported plan/members, admin password from `var.postgres_admin_password` (validation: non-empty when `deploy_postgres`); Quay: a COS bucket (`ibm_cos_bucket`, regional `eu-de`, standard class) in the cluster's COS instance and an `ibm_resource_key` with `HMAC = true`. Same naming/tags.
- [ ] **Step 3: Verify** — as Task 1 Step 3.
- [ ] **Step 4: Commit** — `git commit -s -m "feat(roks): optional IBM Cloud Databases and Quay COS storage"`

---

### Task 3: `roks-deploy` task

**Files:**
- Create: `.tekton/tasks/roks-deploy-task.yaml`, `hack/tekton-tests/test_roks_deploy.sh`

**Interfaces:**
- Consumes: Task 1/2 Terraform variables and outputs.
- Produces (task params): `clusterName` (required), `prNumber` (default `""`), `ibmcloudRegion` (`eu-de`), `ibmcloudResourceGroup` (`redhat-sap-edge-roks-ci`), `openshiftVersion` (`4.21_openshift`), `workerFlavor` (`bx2.16x64`), `workersPerZone` (`"1"`), `roksIbmcloudSecretName` (required), `terraformStateBucket` (required), `terraformStateEndpoint` (default `https://s3.eu-de.cloud-object-storage.appdomain.cloud`), `terraformStateSecretName` (required), `postgresAdminPasswordSecretName` (default `roks-postgres-admin-password`), `deployPostgres`/`deployRedis`/`deployQuay` (`"false"`). Workspace `source` (repo checked out by `git-clone`). Writes `$(workspaces.source.path)/kubeconfig` (admin kubeconfig from output `admin_kubeconfig_path`) and `$(workspaces.source.path)/roks-terraform-outputs.json` (`terraform output -json` with sensitive values removed).
- Behavior: install Terraform ≥ 1.10 and the IBM Cloud CLI + `container-service` plugin; `ibmcloud login --apikey` from the Secret (env var, never echoed) and target region + resource group; `terraform init` with the backend config above (key `roks/<clusterName>/terraform.tfstate`); write `terraform.tfvars` (password from Secret, file mode 600, never printed); `terraform apply -auto-approve`; then ensure the group's infrastructure key: `ibmcloud ks api-key info --cluster <id>` and, if its owner is not the logged-in identity, `ibmcloud ks api-key reset --region <region>`.

- [ ] **Step 1: Write the failing tests** (stub `terraform`, `ibmcloud` scripts in a temp bin dir that log args and emit canned output; drop tool installs with `--drop`): `init_uses_cos_backend` (terraform init args contain `key=roks/redhat-roks-eic-pr7/terraform.tfstate`, `use_lockfile=true`, the endpoint, `bucket=`); `tfvars_contents` (cluster_name, region, resource_group, openshift_version, worker_flavor, workers_per_zone, pr_number, deploy flags; file mode 600); `rerun_same_state_key` (second run with "existing" state uses the identical key and calls `apply`, never a second create path); `infra_key_reset_only_when_owner_differs` (owner == identity → no `api-key reset`; different → exactly one `reset --region eu-de`); `writes_workspace_kubeconfig`; `no_secret_in_output` (fake API key, HMAC keys, Postgres password strings absent from `$TASK_OUT` and from `roks-terraform-outputs.json`); `invalid_cluster_name_fails` (`Redhat_ROKS` → non-zero before any terraform call).
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_roks_deploy.sh` → FAIL (task missing).
- [ ] **Step 3: Implement the task** per Interfaces, structured like `.tekton/tasks/rosa-deploy-with-eic-services-task.yaml`.
- [ ] **Step 4: Verify** — the test, `bash hack/tekton-tests/run.sh`, shellcheck of the extracted script and the test.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(roks): deploy task provisioning ROKS with terraform"`

---

### Task 4: `roks-validate-and-get-access` and `roks-validate-and-create-configmap` tasks

**Files:**
- Create: `.tekton/tasks/roks-validate-and-get-access-task.yaml`, `.tekton/tasks/roks-validate-and-create-configmap-task.yaml`, `hack/tekton-tests/test_roks_access_and_configmap.sh`

**Interfaces:**
- Consumes: workspace `kubeconfig` (admin) and `roks-terraform-outputs.json` from Task 3.
- Produces:
  - `roks-validate-and-get-access`: params `clusterName` (required), `hubKubeconfigSecretName` (default `""`). Mirrors `rosa-validate-and-get-access`: verifies admin access, creates ServiceAccount `cluster-admin-sa` (cluster-admin) with a long-lived token Secret, rewrites `$(workspaces.source.path)/kubeconfig` as a token kubeconfig (the file the shared tasks use), stores Secret `eic-credentials-roks-<clusterName>` (key `kubeconfig`, plus Postgres/Redis connection data when present in the outputs file) on the pipeline cluster, prints the access summary without secret values.
  - `roks-validate-and-create-configmap`: params `clusterName` (required). ConfigMap `cluster-info-roks-<clusterName>` on the pipeline cluster with `host=eic.<ingress subdomain>` (subdomain = output `ingress_hostname`) and `ingressIP` = `istio-ingressgateway` LoadBalancer IP or, if none, its hostname (`endpoint-tests` handles hostnames via `--connect-to`). Result `cluster-summary`.

- [ ] **Step 1: Write the failing tests** (fake `oc`): `access_writes_token_kubeconfig` (SA + token Secret created; workspace kubeconfig contains the token and the cluster server; Secret `eic-credentials-roks-c1` created); `access_no_token_in_output`; `configmap_uses_lb_hostname` (LB has only `hostname` → `ingressIP=<hostname>`, `host=eic.<subdomain>`); `configmap_prefers_lb_ip`.
- [ ] **Step 2: Run to verify they fail** — FAIL (tasks missing).
- [ ] **Step 3: Implement** both tasks, structured like their ROSA counterparts.
- [ ] **Step 4: Verify** — tests, `run.sh`, shellcheck.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(roks): access and test ConfigMap tasks"`

---

### Task 5: `roks-quay-deploy` task

**Files:**
- Create: `.tekton/tasks/roks-quay-deploy-task.yaml`, `hack/tekton-tests/test_roks_quay.sh`

**Interfaces:**
- Consumes: workspace `kubeconfig`; Terraform outputs `quay_cos_bucket`, `quay_cos_endpoint`, `quay_hmac_access_key_id`, `quay_hmac_secret_access_key` (sensitive values read via `terraform output -raw` inside the task, re-initializing the backend like Task 3; never written to the workspace).
- Produces: params `clusterName`, `ibmcloudRegion`, `ibmcloudResourceGroup`, `roksIbmcloudSecretName`, `terraformStateBucket`, `terraformStateEndpoint`, `terraformStateSecretName`, `quayAdminPasswordSecretName` (default `quay-admin-secret`), `hubKubeconfigSecretName`. Deploys Quay like `rosa-quay-deploy` with S3-compatible storage pointing at COS (`s3_bucket`, `host` = COS endpoint host, `s3_region` = `eu-de`).

- [ ] **Step 1: Write the failing tests**: `quay_config_points_to_cos` (captured `apply -f -` QuayRegistry/config Secret contains the bucket and COS host, region `eu-de`); `no_hmac_in_output`.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement**, structured like `.tekton/tasks/rosa-quay-deploy-task.yaml`.
- [ ] **Step 4: Verify** — tests, `run.sh`, shellcheck.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(roks): optional Quay on IBM COS"`

---

### Task 6: `roks-teardown` task and `make roks-destroy`

**Files:**
- Create: `.tekton/tasks/roks-teardown-task.yaml`, `hack/tekton-tests/test_roks_teardown.sh`
- Modify: `roks.makefile` (`roks-destroy` uses the same backend/key as the task)

**Interfaces:**
- Produces: params `clusterName`, `ibmcloudRegion`, `ibmcloudResourceGroup`, `roksIbmcloudSecretName`, `terraformStateBucket`, `terraformStateEndpoint`, `terraformStateSecretName`, `hubKubeconfigSecretName`. Behavior: `terraform init` (same key) → `terraform destroy -auto-approve` with up to 3 attempts; then sweep, in resource group `redhat-sap-edge-roks-ci` only, load balancers and block volumes whose name or tags reference the cluster (`ibmcloud is load-balancers` / `ibmcloud is volumes` filtered by resource group and the cluster id/name tag) and delete them; delete ConfigMap `cluster-info-roks-<cluster>` and Secret `eic-credentials-roks-<cluster>` on the pipeline cluster (`--ignore-not-found`); exit 0 when everything is gone, non-zero with a list when something remains.

- [ ] **Step 1: Write the failing tests**: `destroy_uses_same_state_key`; `destroy_partial_state` (stub terraform destroy fails once then succeeds → retried, exit 0); `sweep_scoped_to_group_and_cluster` (stub `ibmcloud is` lists items in two resource groups / two clusters → only this group + this cluster deleted); `hub_artifacts_deleted`; `no_secret_in_output`.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** the task and align `roks-destroy` in `roks.makefile`.
- [ ] **Step 4: Verify** — tests, `run.sh`, shellcheck, `make -n roks-destroy CLUSTER=redhat-roks-eic-pr7` prints the expected init/destroy commands with key `roks/redhat-roks-eic-pr7/terraform.tfstate`.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(roks): teardown task and make roks-destroy"`

---

### Task 7: Pipeline and example run

**Files:**
- Create: `.tekton/pipelines/roks-eic-full-test-pipeline.yaml`, `.tekton-examples/roks-eic-ossm3-run.yaml`
- Modify: `.config/cspell-words.txt` if needed

**Interfaces:**
- Consumes: Tasks 3–6 params; shared tasks with the same params the ROSA pipeline passes.
- Produces: pipeline params `repoUrl` (required), `revision`, `pullRequestNumber`, `clusterName` (required), `ibmcloudRegion`, `ibmcloudResourceGroup`, `openshiftVersion`, `workerFlavor`, `workersPerZone`, `roksIbmcloudSecretName`, `terraformStateBucket`, `terraformStateEndpoint`, `terraformStateSecretName`, `eicAuthSecretName` (required), `postgresAdminPasswordSecretName`, `quayAdminPasswordSecretName`, `deployPostgres`, `deployRedis`, `deployQuay`, `publicDNS`, `skipAutomatedTests`, `jiraSecretName`, `jiraIssueKey`, `hubClusterName` (required), `ossm3Channel`, `obcName`, `s3Prefix`.
- Graph (mirrors ROSA): `fetch-repository` → `deploy-roks` → `validate-and-get-access` → `deploy-quay` (when `deployQuay`) ; `preflight-check` (`pullSecretName: $(params.roksIbmcloudSecretName)`); `verify-operators` → `apply-rbac` → `prepare-namespaces` → `configure-mesh` → `generate-sa-based-kubeconfig` (all `useWorkspaceKubeconfig: "true"`, `hostedClusterName: $(params.clusterName)`) → `approval-elm-eic-iflow-deployed` (no `when`) → `validate-and-create-configmap` → round-1 tests (ConfigMap `cluster-info-roks-$(params.clusterName)`, automated ones gated by `skipAutomatedTests`) → `approval-second-test-round` → round-2 tests → `update-jira-ticket` (when `jiraIssueKey` notin `[""]`) → `approval-teardown` → `teardown-roks`. Approval and Jira texts say ROKS / IBM Cloud, name the resource group, and contain no credentials.
- Run file: `generateName: roks-eic-full-test-pr{{ pull_request_number }}-`, annotations as the ROSA example (task list adjusted to ROKS tasks), `clusterName: redhat-roks-eic-pr{{ pull_request_number }}`, hub `eic`, `openshiftVersion: 4.21_openshift`, deploy flags `false`, `s3Prefix: restricted-resources/`; secret names as placeholders documented in comments.

- [ ] **Step 1: Write the failing check** — create the run file first; `python3 -I hack/tekton-tests/check_pipeline.py .tekton/pipelines/*.yaml .tekton-examples/roks-eic-ossm3-run.yaml` → Expected: FAIL (unknown pipeline).
- [ ] **Step 2: Implement the pipeline** per the graph.
- [ ] **Step 3: Verify** — the checker command above and `bash hack/tekton-tests/run.sh` → PASS; no ApprovalTask has `when`; `grep -c skipEicValidation` on both files → 0.
- [ ] **Step 4: Commit** — `git commit -s -m "feat(tekton): ROKS EIC validation pipeline"`

---

### Task 8: Documentation

**Files:**
- Modify: `.tekton/README.md` (ROKS section), `roks/terraform/README.md` (complete)

- [ ] **Step 1: Write** the one-time setup (service ID `redhat-sap-edge-roks-ci` with API key and access to VPC Infrastructure, Kubernetes Service, Cloud Object Storage and Databases in the resource group; Secret with `IBMCLOUD_API_KEY`; COS state bucket + HMAC Secret; how to start the example run; `make roks-destroy CLUSTER=…` after failed runs; the naming/tag convention so IBM colleagues recognize the resources).
- [ ] **Step 2: Verify** — `npm run cspell`, `.venv/bin/reuse lint`, links resolve.
- [ ] **Step 3: Commit** — `git commit -s -m "docs(roks): setup and usage for the ROKS pipeline"`

---

## After all tasks

- [ ] `bash hack/tekton-tests/run.sh`, `python3 -I hack/tekton-tests/check_pipeline.py .tekton/pipelines/*.yaml .tekton-examples/*-run.yaml`, `make roks-tflint roks-tfsec roks-checkov`, `npm run cspell`, `.venv/bin/reuse lint` all clean.
- [ ] Ask the user before any `terraform apply` against IBM Cloud or any push: a real run costs money and needs the one-time setup.
