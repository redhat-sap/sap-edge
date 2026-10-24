<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# Multi-EIC restricted-resources deployment convention (norm)

Date: 2026-10-17

## Status

- **Topology A — shared core**: specified here and to be implemented.
- **Topology B — 1:1:1 stacks**: specified as a described extension; implemented
  later as its **own pipeline**, not now.

## Why

SAP changed the restricted-resources bundles from "RBAC-only" to **self-contained,
ordered install bundles**: numbered manifests (`000001-*.yaml` …) that create
their own namespaces (with ownership labels), ship CRDs/roles/rolebindings and a
`restricted-resources-hash` ConfigMap, plus an `apply-restricted-resources.sh`
that validates namespace ownership and applies the bundle in order.

We need a repeatable convention for deploying **multiple Edge Integration Cells
("cells") on one OpenShift cluster** so the pipeline can locate, order, and apply
the right bundles and correctly overlay the dedicated-mesh labels and SCC
annotations across cells whose namespaces are operator-configurable.

## Key facts / constraints

1. **Bundles self-create namespaces and enforce ownership.** Each namespace is
   stamped `edgelm.sap.com/product=edgelm` and `edgelm.sap.com/edge-node-id=<uuid>`;
   `apply-restricted-resources.sh` refuses (CONFLICT) to co-opt a namespace owned
   by a different edge node. Ownership is enforced **per namespace**, and EIC cell
   bundles do **not** take ownership of the shared `edgelm` namespace (it is not in
   their `REQUIRED_NAMESPACES`; they only bind the shared `edgelm` SA into their own
   cell namespaces). So cells coexist on one cluster as long as they have
   **distinct namespace names** — whether or not they share one `edge-node-id`.
   No extra preflight guard is needed: SAP's per-bundle `apply-restricted-resources.sh`
   already validates ownership for each bundle it applies.
2. **Cluster-scoped resources are singletons.** CRDs (e.g. `xbem`, the ELM CRDs)
   and the ELM `ClusterRole`/`ClusterRoleBinding` exist once per cluster. All
   co-resident cells share one CRD version, so SAP must keep CRDs
   backward-compatible across co-hosted versions; whichever bundle applies last
   wins → **apply ELM first, deterministically**.
3. **Old selection logic collapsed cells.** The task previously kept the latest
   version *per resource type across the whole prefix*, so two
   `Edge_Integration_Cell` bundles reduced to one. Replaced by per-component
   selection (below).
4. **Injection label mismatch.** Bundles set `istio-injection=enabled` on the
   mesh namespaces (main, ela, services, gateways) and omit it on the secrets
   namespace. Dedicated mesh needs `istio.io/rev` instead, so the overlay strips
   `istio-injection` and sets the revision.
5. **Bundles do not set SCC annotations.** The overlay sets them, per role.

## Naming convention

The cell index is a **trailing `-N`** appended to each base role name. Namespace
names are operator-configured when the bundle is generated; cells on one cluster
MUST follow this scheme.

| Role                 | Base name             | Cell 1                  | Cell 2                  |
|----------------------|-----------------------|-------------------------|-------------------------|
| main                 | `edge-icell`          | `edge-icell-1`          | `edge-icell-2`          |
| secrets              | `edge-icell-secrets`  | `edge-icell-secrets-1`  | `edge-icell-secrets-2`  |
| ela                  | `edge-icell-ela`      | `edge-icell-ela-1`      | `edge-icell-ela-2`      |
| services             | `edge-icell-services` | `edge-icell-services-1` | `edge-icell-services-2` |
| gateways             | `istio-gateways`      | `istio-gateways-1`      | `istio-gateways-2`      |
| edgelm (topology A)  | `edgelm`              | shared `edgelm`         | shared `edgelm`         |

**Role detection:** strip the trailing `-<digits>`, then exact-match the base
name. e.g. `edge-icell-services-2` → `edge-icell-services` → services role.

## S3 layout convention

One **fixed prefix per cluster deployment** (the "set"), one subfolder per
component, named by the component (`elm` for the shared manager):

```
restricted-resources/<deployment>/          <-- = pipeline s3Prefix param
  elm/            restricted-resources-Edge_Lifecycle_Management-<ver>.zip
  edge-icell-1/   restricted-resources-Edge_Integration_Cell-<ver>.zip
  edge-icell-2/   restricted-resources-Edge_Integration_Cell-<ver>.zip
```

- One bundle zip per subfolder; **latest version within a subfolder wins**.
- Add a cell → add a subfolder. Upgrade a cell → drop its newer zip in its
  subfolder. Non-destructive; versions independent per cell; recorded per run.
- The dedicated pipeline creates the folders for you: set
  `restrictedResourcesComponents` (e.g. `elm edge-icell-1 edge-icell-2`) and it
  creates them under `s3Prefix`, then pauses at
  `approval-upload-restricted-resources` (in parallel with cluster creation)
  with upload instructions and each folder's current contents. After
  approval, `apply-rbac` fails fast if a listed folder holds no zip. The gate
  always pauses (ApprovalTasks cannot be skipped conditionally); with the
  bundles already in place, approve it straight away.
- A **flat prefix** (zips directly under it, no subfolders) is treated as a
  single component — preserves single-EIC runs. Note: ELM-first apply ordering
  (below) is applied **universally**, including the flat path. Today's flat path
  happens to apply EIC before ELM (incidental `find | sort` order); standardizing
  on ELM-first is safe (shared CRDs/cluster-admin first never hurts) and matters
  once a deployment has its own `elm/` component.

### Component model: gateways are embedded in the EIC bundle

In the **new** bundle format, the `istio-gateways` namespace, its roles/bindings,
and the `restricted-resources-hash` ConfigMap ship **inline inside each EIC
bundle** (files `000017`–`000022` in the example EIC bundle). There is **no separate
`IstioGateways` component or subfolder.** Apply ordering therefore classifies by
the **resource-type token in the zip filename** (`Edge_Lifecycle_Management`,
`Edge_Integration_Cell`, …), not by subfolder name. The `IstioGateways` priority
tier (10) is retained only to correctly order a standalone gateways bundle *if*
SAP ever ships one again; with today's bundles it simply never matches.

## Role → mesh / SCC table (same values for all cells)

| Base role             | `istio.io/rev` (mesh) | SCC `uid-range` | SCC `supplemental-groups` |
|-----------------------|-----------------------|-----------------|---------------------------|
| `edgelm`              | yes                   | —               | `67000/1000`              |
| `edge-icell` (main)   | yes                   | `10000/100`     | `1000/100`                |
| `edge-icell-ela`      | yes                   | `100000/1000`   | `100002/1000`             |
| `edge-icell-services` | yes                   | `1000000/1000`  | `1000002/1000`            |
| `edge-icell-secrets`  | no                    | —               | —                         |
| `istio-gateways`      | yes                   | —               | —                         |

For cell N, apply the same values to each `<role>-N` namespace. Values are taken
from today's single-cell `ossm3-prepare-namespaces-dedicated` task.

## Pipeline behavior — Topology A (to implement)

**Scope: provisioning only.** We make the three *provisioning* tasks multi-cell
via discovery so that namespaces, RBAC, and mesh membership are set up correctly
for every cell present. The **downstream** tasks — EIC service deploy, routing
(`hcp-create-eic-route`), `hcp-fix-endpointslice`,
`hcp-validate-and-create-configmap`, endpoint/rate-limit tests, and the approval
step — **remain single-cell** (they validate the first cell). Making those
per-cell (N routes, N gateways, N test suites) is a documented **follow-up**,
most naturally done alongside the Topology B pipeline work; it is out of scope
here.

Reuse the existing `hcp-ossm3-dedicated-validation` pipeline (single istio
control plane, one shared `edgelm`). Three tasks change; all become
discovery-driven instead of hardcoding the single-cell namespace list.

1. **`ossm3-download-and-apply-rbac` (Steps 2–3).** Discover each directory that
   contains `*.zip` under the downloaded prefix (= one component); within each,
   pick the latest version per resource type; extract into order-prefixed dirs so
   apply order is **ELM (00) → IstioGateways (10) → EIC cells (20)**, cells
   ordered by name. Step 4 (run each bundle's `apply-restricted-resources.sh
   --yes`) is unchanged. A flat prefix = one component (back-compat).

2. **`ossm3-prepare-namespaces-dedicated`.** Replace the hardcoded
   `NAMESPACES=(…)` list with discovery:
   - namespaces = `oc get ns -l edgelm.sap.com/product=edgelm`;
   - mesh labelling: for each such ns carrying `istio-injection=enabled`, set
     `istio.io/rev=sap-mesh-istio` and strip `istio-injection`;
   - SCC: strip trailing `-N`, match base role, apply the table above
     (secrets/gateways get none).

3. **`ossm3-configure-dedicated-mesh`.** Replace the hardcoded `APP_NAMESPACES`
   list with discovery, but select by **`istio.io/rev=sap-mesh-istio`** (the label
   `prepare-namespaces-dedicated` already set), *not* by `istio-injection`. This
   task `runAfter: prepare-namespaces-dedicated`, which by then has already
   stripped `istio-injection`, so keying on it would select nothing; keying on the
   revision label selects exactly the mesh namespaces and keeps the secrets
   namespace out. Then label those with `istio-discovery=sap-edge-mesh`. The single
   control plane and the `edgelm` `ServiceEntry` are unchanged (edgelm is shared
   in topology A).

## Topology B (described; future, separate pipeline)

N independent stacks (`edgelm-N` + `edge-icell-N` + its own istio instance). Each
cell N gets its **own** control plane with revision `sap-mesh-istio-N`, and that
cell's namespaces get `istio.io/rev=sap-mesh-istio-N`. Implement as a dedicated
pipeline (e.g. `hcp-ossm3-multi-stack-validation-pipeline.yaml`) reusing the
shared `download-and-apply-rbac` task, with `prepare-namespaces` / `configure-mesh`
variants that loop per stack and derive the revision from the `-N` index. Not
implemented now.

## Goals / non-goals / anti-goals

- **Goal:** deterministic, non-destructive multi-cell deploy from a single S3
  prefix; correct mesh + SCC overlay for any operator-configured cell names
  following the `-N` convention.
- **Non-goal (now):** topology B implementation; per-cell SCC isolation (we apply
  the same SCC values to every cell); per-cell downstream validation (EIC deploy,
  routes, endpoint/rate-limit tests stay single-cell — see Scope above).
- **Anti-goal:** delete-and-reupload bundle management; hardcoding or guessing
  namespace names in the pipeline.

## Left to the builder

- Exact bash for discovery + role parsing. Runtime is UBI9 bash 5.x; keep the
  embedded scripts shellcheck-clean (CI lints standalone `*.sh` only, but lint
  embedded scripts by hand) and prefer bash-3.2-testable idioms where practical.
- Confirm `ossm3-configure-dedicated-mesh`'s single-control-plane path needs no
  other per-cell change for topology A beyond the `APP_NAMESPACES` discovery.
- Update the run file(s) / `s3Prefix` usage and any doc references to point at the
  per-deployment prefix convention.
