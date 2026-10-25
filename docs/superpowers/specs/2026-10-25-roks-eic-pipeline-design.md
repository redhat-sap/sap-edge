<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# Design: ROKS (Red Hat OpenShift on IBM Cloud) EIC validation pipeline

Date: 2026-10-25
Status: approved by the user (2026-10-25)

## Intent

Validate SAP Edge Integration Cell (EIC) with restricted-access onboarding on
**ROKS** — Red Hat OpenShift on IBM Cloud — the same way the repo already does
for ROSA (AWS) and ARO (Azure). A run provisions a ROKS cluster per PR with
Terraform, prepares it for SAP ELM, pauses while the user registers the
cluster in ELM and deploys EIC, runs the endpoint tests, and tears the cluster
down.

## The user's flow (confirmed by the user)

1. Terraform creates a ROKS cluster on IBM Cloud for the PR.
2. The pipeline applies the restricted-access resources, sets up the service
   mesh and generates the restricted kubeconfig.
3. The user registers the cluster in ELM and deploys EIC; the endpoint tests
   run.
4. Terraform deletes the cluster at the end.

## Goals

- New pipeline `roks-eic-full-test-pipeline` and example PipelineRun
  `.tekton-examples/roks-eic-ossm3-run.yaml`, modelled on
  `rosa-eic-full-test-pipeline` / `.tekton-examples/rosa-eic-ossm3-run.yaml`
  (same phases, same approvals, same test rounds, same Jira update, same
  params where the meaning is the same).
- Infrastructure as code: `roks/terraform/` (sibling of `rosa/terraform/`)
  using the official `IBM-Cloud/ibm` Terraform provider.
- Reuse every cloud-agnostic task unchanged, wired exactly as in the ROSA
  pipeline (against the workspace kubeconfig, `useWorkspaceKubeconfig: "true"`):
  `ossm3-preflight-check`, `ossm3-verify-operators`,
  `ossm3-download-and-apply-rbac` (flat `restricted-resources/` prefix),
  `ossm3-prepare-namespaces`, `ossm3-configure-mesh` (shared mesh),
  `ossm3-generate-sa-based-kubeconfig`, `endpoint-tests`, `rate-limit-test`,
  `jira-add-comment-custom`, `git-clone`, and the ApprovalTasks.
- New ROKS tasks, one per ROSA counterpart:
  - `roks-deploy` — install Terraform + IBM Cloud CLI, `terraform apply` of
    `roks/terraform/`, wait for the cluster to be normal and workers ready.
  - `roks-validate-and-get-access` — fetch an admin kubeconfig, write it to
    the workspace (`kubeconfig`, same contract the shared tasks expect), verify
    access, print the access summary.
  - `roks-validate-and-create-configmap` — find the EIC host and ingress
    address for the tests (ConfigMap with `host` and `ingressIP`, same format
    as ROSA's).
  - `roks-quay-deploy` — optional Quay backed by IBM Cloud Object Storage.
  - `roks-teardown` — `terraform destroy` plus cleanup of pipeline-side
    artifacts (ConfigMaps, Secrets on the hub), tolerant of partial state.
- Optional managed backing services, mirroring ROSA's `deployPostgres` /
  `deployRedis`: IBM Cloud Databases for PostgreSQL and for Redis, created by
  the same Terraform when the flags are `true` (default `false`).

## Non-goals

- Multi-EIC (topology A/B) on ROKS; ROKS runs one EIC with default namespace
  names and the shared mesh, like ROSA/ARO today.
- ROKS on IBM Cloud Satellite or classic infrastructure (VPC Gen2 only).
- Refactoring the ROSA/ARO pipelines or their tasks.
- Triggering ROKS on every PR (the run file lives in `.tekton-examples/`,
  started on demand, like the ROSA/ARO examples).

## Anti-goals

- Leaving billable IBM Cloud resources behind after a run that reached
  teardown (cluster, VPC, COS, databases); teardown must work from Terraform
  state even if the cluster is already half gone.
- Touching anything outside the dedicated resource group (in particular the
  `Default` group, where the user's own ROKS cluster runs on the user's
  infrastructure key).
- Credentials in task results, approval descriptions or logs.
- Changes to shared tasks that alter behavior for other pipelines.

## Constraints

- Cluster access for the shared tasks comes only from the workspace
  `kubeconfig` file (that is how ROSA/ARO feed them).
- ApprovalTasks cannot be skipped conditionally on this cluster (they ignore
  `when`). Gates must not carry `when` (the ROSA pipeline's gates do — a known
  pre-existing defect not to copy).
- Embedded scripts: UBI9 bash, `set -euo pipefail`, shellcheck-clean at
  default severity; new standalone `*.sh` are linted by CI. SPDX headers;
  `npm run cspell` clean; DCO sign-off; PRs to `redhat-sap/sap-edge`.
- The local harness `hack/tekton-tests/` (wiring checker + task-script tests)
  must pass and cover the new tasks.

## Account facts (checked read-only with the IBM Cloud CLI, 2026-10-25)

- Account `Redhat` (`beed1d6734f1433ab88654eb043db9e2`); the user is in its
  Admin access group.
- Resource groups: `Default` (account default, shared), `oalbrigt-rhel9`,
  `vapor-images` (other people's), and **`redhat-sap-edge-roks-ci`** — created
  for this pipeline on 2026-10-25 (ID `a80f479864f944c1b3d9a62e98e70a62`).
- The user's existing cluster `mycluster-eu-de-1-bxf.4x16` (OpenShift
  4.21.31, 9 × `bxf.4x16`, VPC, `eu-de`) lives in `Default`; the `eu-de` /
  `Default` infrastructure API key is owned by the user.
- Entitlement of the existing cluster: `default` (regular OpenShift license,
  no Cloud Pak). Default ROKS pod subnet `172.17.0.0/18`, service subnet
  `172.21.0.0/16`; ingress subdomain `*.eu-de.containers.appdomain.cloud`.
- `bx2.16x64` and `bxf.16x64` are offered in `eu-de-1`.

## Decided by the user

- Same flow as the ROSA run (see above).
- **Dedicated resource group `redhat-sap-edge-roks-ci`**, with "redhat" in
  the name so IBM colleagues can see whose resources these are.

## My calls (the user delegated these)

- **Naming and tags:** every IBM resource the pipeline creates is prefixed
  `redhat-` (cluster `redhat-roks-eic-pr{{ pull_request_number }}`, VPC,
  subnets, gateways, COS, databases) and tagged `owner:redhat`,
  `project:sap-edge`, `pr:<N>` — extending the user's naming wish.
- **Resource group and infrastructure key:** all resources go into
  `redhat-sap-edge-roks-ci`. `roks-deploy` ensures that group's `eu-de`
  infrastructure key belongs to the pipeline's API key (safe because the
  group is dedicated). `roks-teardown` may sweep leftover load balancers and
  block volumes tagged for the run's cluster in that group only.
- **Entitlement:** none (regular license), matching the existing cluster.
- **Network ranges:** VPC address prefixes inside `10.0.0.0/16` and ROKS
  `pod_subnet` `10.128.0.0/14` (service subnet left at the ROKS default), so
  the `httpbinipfilter` iFlow allowlist that already covers ROSA covers ROKS.
- **Failure policy:** like ROSA/ARO/HCP, a failed or rejected run leaves the
  cluster for debugging (no `finally` teardown). A supported manual path
  `make roks-destroy CLUSTER=<name>` (in `roks.makefile`) destroys from the
  Terraform state. Gates carry no `when`; ROSA's `skipEicValidation` (which
  relies on `when` on gates) is dropped; `skipAutomatedTests` is kept.
- **State locking:** `use_lockfile = true` on the COS-backed `s3` backend; if
  COS does not enforce conditional writes the lock is best-effort, acceptable
  because each PR has its own state key and `cancel-in-progress` serializes
  runs.

- **Layout:** `roks/terraform/` + `roks.makefile` (mirrors `rosa/terraform/` +
  `rosa.makefile`) for local use.
- **Terraform version:** ≥ 1.10 (needed for S3-native state locking below);
  installed at runtime in the task like ROSA does.
- **Terraform resources:** VPC, one subnet per zone across 3 zones of the
  region, public gateways (worker egress), a COS instance (required by ROKS on
  VPC for the internal registry), `ibm_container_vpc_cluster` (OpenShift
  `kube_version` from a param, worker flavor `bx2.16x64`, 1 worker per zone =
  3 workers), and optional `ibm_database` PostgreSQL / Redis. Outputs: cluster
  id/name, ingress hostname, COS bucket/endpoint for Quay, database endpoints.
- **Admin kubeconfig:** Terraform data source `ibm_container_cluster_config`
  with admin credentials (no `ibmcloud` login needed for this), written to the
  workspace by `roks-validate-and-get-access`.
- **Terraform state:** an existing IBM Cloud Object Storage bucket, used
  through Terraform's `s3` backend (COS is S3-compatible) with
  `use_lockfile = true` for locking (no DynamoDB equivalent needed); one state
  file per cluster (`roks/<cluster>/terraform.tfstate`), like ROSA.
- **Defaults:** region `eu-de` (Frankfurt), resource group
  `redhat-sap-edge-roks-ci`, OpenShift version param in the run file (start
  with the 4.21 line the account already runs), cluster name
  `redhat-roks-eic-pr{{ pull_request_number }}`, OSSM channel as in the ROSA
  run, hub `eic`, `deployPostgres`/`deployRedis`/`deployQuay` `false`.
- **Credentials (Secrets in the pipeline namespace):** IBM Cloud API key
  (`roksIbmcloudSecretName`, key `IBMCLOUD_API_KEY`) — preferably a service
  ID's key with access scoped to `redhat-sap-edge-roks-ci`, so it is not tied
  to a person — and COS HMAC keys for the state bucket
  (`terraformStateSecretName`, keys `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY`). Postgres admin password Secret as in ROSA.

## One-time setup the user does (documented in the README section)

- (Done) resource group `redhat-sap-edge-roks-ci`.
- A service ID (e.g. `redhat-sap-edge-roks-ci`) with an API key and access
  to VPC Infrastructure, Kubernetes Service, Cloud Object Storage and Databases
  in that resource group.
- A COS bucket for Terraform state plus HMAC credentials, stored as the state
  Secret; the API-key Secret.

## Left to the builder

- Exact Terraform module structure (raw resources vs IBM's
  `terraform-ibm-modules` base-ocp-vpc module) — pick what keeps destroy
  reliable; pin provider versions.
- ROKS VPC load balancers expose a hostname, not an IP: how
  `roks-validate-and-create-configmap` turns it into the `ingressIP` the tests
  need (ROSA already falls back to the hostname; check what `endpoint-tests`
  accepts).
- Storage classes for Quay/ELM on ROKS (block vs file) and whether any EIC
  component needs RWX.
- Exact params of the new tasks (follow ROSA's names where meaning matches).
- README/docs placement, and harness tests for the new task scripts.
