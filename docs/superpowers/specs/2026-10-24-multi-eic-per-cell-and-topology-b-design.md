<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# Design: per-cell multi-EIC validation (topology A) and topology B

Date: 2026-10-24
Status: approved by the user (2026-10-24)

## Intent

Validate, on a fresh HCP KubeVirt cluster per PR, that **two SAP Edge
Integration Cell (EIC) instances** run side by side on one OpenShift cluster
with restricted-access onboarding, and that **each cell works end to end**
(endpoint and rate-limit tests against each cell's own gateway). Two
deployment models, one pipeline each:

- **Topology A** — one Edge Node, one shared ELM (`edgelm`) and one shared
  dedicated mesh, two cells. Pipeline `hcp-ossm3-dedicated-validation`
  (exists; provisioning is already multi-cell, this design makes its
  backing services and validation per cell).
- **Topology B** — two Edge Nodes, each with its own ELM, its own EIC and its
  own Istio control plane ("Scenario 2: Multiple Edge Nodes with Dedicated
  Meshes"). New pipeline `hcp-ossm3-multi-stack-validation`.

Sources (authoritative when this document is silent):

- `docs/multi-eic-restricted-resources-convention.md` — naming, S3 layout,
  role → SCC table, topology A provisioning (already implemented).
- KBA 7131840 — restricted access with OSSM 3.x, incl. "Advanced: Dedicated
  Service Mesh for an Edge Node" and "Assign SAP Namespaces to the Dedicated Mesh".
- KBA 7149262 — multiple EIC instances: backing-service isolation, Scenario 2
  deployment sequence, "Keep Mesh Assignments Separate", verification commands.

## What a run looks like (the user's flow, both topologies)

1. Push the PR. The pipeline creates the per-PR S3 folders and pauses at the
   upload gate, in parallel with hosted-cluster creation (already built:
   `ossm3-prepare-restricted-resources-prefix` + `approval-upload-restricted-resources`).
2. Upload one zip per folder exactly as downloaded from SAP ELM; approve.
3. The pipeline applies the bundles, sets up mesh(es), namespace labels and SCC
   annotations, restricted kubeconfig(s), and isolated backing services per cell.
4. Approval: the user registers the Edge Node(s) in ELM, deploys each EIC with
   its own virtual host and backing services, deploys the iFlows to each cell.
5. The pipeline runs, **per cell**, the same three test rounds as today
   (load-balancer round, second round, Route round — each round gated by its
   existing approval, which now covers all cells), updates Jira, then the
   teardown approval and teardown.

## Decided by the user

- **Naming: always `-N`.** Every SAP namespace of cell/stack N ends in `-N`
  (`edge-icell-1`, `edge-icell-secrets-1`, `istio-gateways-1`, …; topology B
  also `edgelm-1`, `edgelm-2`). Names are configurable in ELM; the user sets
  them this way. The legacy unsuffixed single-cell mode (`edge-icell`,
  `istio-gateways`, host `eic.`) is **dropped** from the dedicated pipeline.
- **Single cell = cell count 1.** The pipelines are written for two cells.
  Topology A gets a `cellCount` param (default `2`); with `1`, **every
  cell-2 step downstream is skipped** (backing services, ConfigMap, endpoint
  slice fix, Route, all tests) via `when`. Regular tasks support `when`;
  ApprovalTasks do not, and they cover all cells anyway.
- **Per-cell tests: all three rounds** for every cell, both topologies.
- **One shared `eic-auth-secret`** for all cells (same iFlow credentials).
- **Topology B:** ELM is not shared (`edgelm-1`, `edgelm-2`) and the mesh is
  not shared (one control plane per Edge Node).
- **Backing services** (via the external-service scripts' existing
  `--instance` option, commit a6e86d0):
  - **Redis/Valkey: always a separate instance per cell**, both topologies.
  - **Postgres: deployed once, exactly as today; all cells share the same
    database** — both topologies (no `--instance`).
- **Per-PR S3 prefix** (`restricted-resources/pr{{ pull_request_number }}/` for A).

## Goals

### Shared task changes (all backward compatible: defaults = today)

Used by up to four other pipelines (`hcp-kubevirt-validation`,
`hcp-cloud-connector-validation`, `hcp-ossm3-validation`, ARO/ROSA for the
kubeconfig task); their behavior must not change.

| Task | Change |
|---|---|
| `hcp-validate-and-create-configmap` | optional gateway namespace (default: today's search), host prefix (default `eic`), ConfigMap name (default `cluster-info-hcp-<cluster>`) |
| `hcp-create-eic-route` | optional gateway namespace and host prefix; Route name unique per cell |
| `hcp-fix-endpointslice` | optional guest service namespace — today it picks the first `istio-ingressgateway` by name, ambiguous with two gateways |
| `hcp-deploy-redis` / `-valkey` | optional `instance` → `--instance` (default empty) |
| `hcp-get-all-accesses` | optional `instance` → `--instance` for `get_all_accesses.sh` |
| `ossm3-generate-sa-based-kubeconfig` | optional ELM namespace (default `edgelm`) and generated Secret name; SA name taken from the bundle's RBAC in that namespace (KBA 7131840 "CRITICAL") |
| `hcp-enable-monitoring` / `hcp-verify-monitoring` | opt-in discovery of the EIC main/services and ELM namespaces by label + role (default: today's fixed list) |
| `ossm3-configure-dedicated-mesh` | topology A fix: put `istio-discovery` on **every** SAP namespace incl. secrets (KBA 7131840); `istio.io/rev` stays workload-only |

`endpoint-tests` and `rate-limit-test` are unchanged (they already take the
ConfigMap name and auth Secret name).

### Per-cell downstream (both pipelines)

For each cell N (N = 1, 2):

- Redis/Valkey with `instance=eic-N`, in its own namespace (e.g.
  `sap-eic-external-redis-eic-N`).
- Postgres: deployed once (unchanged task call); all cells use the same
  database.
- Access info per cell (`hcp-get-all-accesses` with `instance=eic-N`; every
  cell shows the same Postgres database and its own Redis/Valkey).
- ConfigMap `cluster-info-hcp-<cluster>-N`: `host=eic-N.<ingress domain>`,
  `ingressIP` from `istio-ingressgateway` in `istio-gateways-N`.
- Endpoint-slice fix for `istio-gateways-N/istio-ingressgateway`.
- Route in `istio-gateways-N` with host `eic-N.<ingress domain>`.
- Tests per round: `/httpbinipfilter` (when enabled), `/http/test1`,
  `/http/testelster`, `/slvredis`, rate-limit on `/slvredis` — against
  ConfigMap `…-N`, shared `eic-auth-secret`. Three rounds as today.
- Approvals (ELM/EIC deployed, second round, Route round, teardown) stay one
  per round; their text lists every cell (host, gateway namespace, backing
  services). Jira update waits for all cells' Route-round tests.
- Monitoring covers all cells' namespaces.

### Topology A pipeline (`hcp-ossm3-dedicated-validation`)

- New param `cellCount` (default `2`); cell-2 tasks guarded by `when`.
- Run file `.tekton/hcp-ossm3-dedicated-validation-run.yaml`: `cellCount: "2"`,
  components `elm edge-icell-1 edge-icell-2` (already set).
- `.tekton-examples` dedicated runs (incl. proxy variant) updated to the `-N`
  scheme (`cellCount: "1"`, components `elm edge-icell-1`, per-PR prefix).
- Provisioning unchanged apart from the secrets discovery-label fix.

### Topology B pipeline (`hcp-ossm3-multi-stack-validation`, new)

Same phases and per-cell downstream as topology A, with per-Edge-Node
provisioning. Nothing shared between stacks except the Service Mesh operator,
the cluster-wide IstioCNI, cluster-scoped CRDs and the Postgres database.

| Per stack N | Value |
|---|---|
| ELM namespace | `edgelm-N` |
| EIC namespaces | `edge-icell-N`, `edge-icell-secrets-N`, `edge-icell-ela-N`, `edge-icell-services-N`, `istio-gateways-N` |
| Control plane ns / Istio name / discovery value | `istio-system-sap-edge-N` / `sap-mesh-istio-N` / `sap-edge-mesh-N` |
| Injection label | `istio.io/rev=<active revision of mesh N>`, read from the running control plane |
| Restricted kubeconfig Secret | `edgelm-kubeconfig-generated-<cluster>-N` |
| Proxy ServiceEntry (if proxy) | in `edgelm-N` |
| S3 folders | `elm-N/`, `edge-icell-N/` |

- S3 prefix `restricted-resources/pr{{ pull_request_number }}-multi-stack/` —
  a **sibling** of A's prefix, not a subfolder (A downloads its prefix
  recursively and would pick up B's bundles).
- Order: `apply-rbac` → `ossm3-configure-multi-stack-mesh` →
  `ossm3-prepare-namespaces-multi-stack` → kubeconfigs and backing services
  → approval → per-cell downstream. Mesh before namespace labels (reverse of
  A) because the revision is read from the running control plane.
- New task `ossm3-configure-multi-stack-mesh`: discover stacks; IstioCNI once;
  per stack create control plane ns + Istio with
  `discoverySelectors: istio-discovery=sap-edge-mesh-N` (+ DNS-capture proxy
  metadata when a proxy is configured, as in `ossm3-configure-dedicated-mesh`);
  wait Ready; label the control plane ns; proxy ServiceEntry in `edgelm-N`;
  check that no two Istio resources on the cluster have overlapping discovery
  selectors.
- New task `ossm3-prepare-namespaces-multi-stack`: per stack read the active
  revision; label all the stack's namespaces `istio-discovery=sap-edge-mesh-N`;
  workload namespaces (`istio-injection=enabled` or already on revision N)
  `istio.io/rev=<rev>`; remove `istio-injection`; never an injection label on
  secrets; SCC per role; preserve ownership labels; print the KBA 7149262
  verification view (`oc get ns -L edgelm.sap.com/edge-node-id,istio-discovery,istio.io/rev,istio-injection`).
- Stack discovery/validation: SAP namespaces = `edgelm.sap.com/product=edgelm`;
  stack N = names ending `-N`; fail clearly if a SAP namespace has no `-N`,
  a stack has no `edgelm-N`, namespaces in one stack have different
  `edgelm.sap.com/edge-node-id`s, or two stacks share one (that is topology A).
- One kubeconfig per stack (`ossm3-generate-sa-based-kubeconfig` with ELM
  namespace `edgelm-N`).
- Fixed at two stacks (no `cellCount`): one stack would just be topology A.
- Run file `.tekton/hcp-ossm3-multi-stack-validation-run.yaml`, cluster
  `hcp-multistack-pr{{ pull_request_number }}`, components
  `elm-1 edge-icell-1 elm-2 edge-icell-2`, otherwise like the dedicated run.
- Minimum releases: ELM 1.64, EIC 8.48 (KBA 7149262).

## Non-goals

- More than one EIC instance per Edge Node in topology B, or more than two
  cells/stacks (adding one = copying the per-cell pipeline blocks).
- Dynamic cell count in the pipeline graph beyond A's `cellCount` 1/2.
- Changing the ARO/ROSA/shared-mesh pipelines beyond keeping them working
  with the backward-compatible task params.

## Anti-goals

- A legacy/unsuffixed special case anywhere in the multi-EIC pipelines.
- Any cell-2 task that fails (rather than skips) when `cellCount=1`.
- Sharing between B's stacks beyond the list above; a control plane whose
  discovery selector matches another stack's namespaces; one kubeconfig/SA
  for two Edge Nodes.
- Guessing namespace names or the injection revision.
- Selecting by `edgelm.sap.com/product=edgelm` alone for anything
  destructive (KBA 7149262: the label spans Edge Nodes).
- Credentials in approval descriptions or task results.

## Constraints

- ApprovalTasks cannot be skipped conditionally on this cluster (they ignore
  `when`; computed timeouts also fail). Every gate pauses every run.
- Tekton `matrix` is unused in this repo and unverified on the cluster: per-cell
  pipeline tasks are spelled out (`…-1`, `…-2`).
- Verify on the cluster's Tekton version that a `when`-skipped cell-2 task
  does not skip its non-cell-2 dependents (approvals, Jira, teardown).
- Cluster-scoped ELM RBAC carries a per-node suffix (no collision between
  Edge Nodes); ELM bundles apply before EIC bundles (already true).
- Embedded scripts: UBI9 bash 5.x, shellcheck-clean at default severity,
  bash-3.2-testable where practical (guard empty arrays under `set -u`).
- Commits signed off (DCO); PRs to `redhat-sap/sap-edge` from the fork.

## Left to the builder

- Exact bash for stack grouping/validation and revision lookup
  (`istio` status vs `istiorevisions` on OSSM 3.2).
- How CAPK labels let `hcp-fix-endpointslice` tell the two gateways apart
  (e.g. a tenant-service namespace label) — verify on a real cluster.
- How the monitoring tasks opt into discovery (param shape).
- How approvals show per-cell access info, as long as passwords stay as
  visible to the approver as today (task logs) and never in descriptions.
- Worker sizing for two cells / two stacks (current: 3 × 16 vCPU / 32 GB).
- Keeping the two large pipelines maintainable (e.g. consistent block
  ordering); committed YAML stays plain Tekton.
- Updating `docs/multi-eic-restricted-resources-convention.md` (Status,
  scope, topology B section, S3 layout) to match what gets built.
