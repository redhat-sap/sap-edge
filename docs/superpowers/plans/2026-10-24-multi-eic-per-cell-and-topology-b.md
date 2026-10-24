<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
-->

# Multi-EIC per-cell validation and Topology B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `hcp-ossm3-dedicated-validation` (topology A) validate two EIC cells end to end, and add `hcp-ossm3-multi-stack-validation` (topology B: two Edge Nodes, each with its own ELM and mesh).

**Architecture:** Shared Tekton tasks gain optional, default-preserving params (gateway namespace, host prefix, ConfigMap names, instance, ELM namespace) so the same task serves cell 1 and cell 2. Two new tasks build and label one dedicated mesh per Edge Node. Both pipelines spell out per-cell task blocks with a `cell1-` / `cell2-` name prefix; topology A gates `cell2-*` on `cellCount`. A small local harness (script extractor + fake `oc` + pipeline wiring checker) tests the embedded bash and the pipeline graphs.

**Tech Stack:** Tekton v1 Tasks/Pipelines (OpenShift Pipelines + PaC), bash 5 (UBI9) embedded scripts, OSSM 3.x (sailoperator.io/v1), Python 3 + PyYAML for the harness.

**Spec:** `docs/superpowers/specs/2026-10-24-multi-eic-per-cell-and-topology-b-design.md`

## Global Constraints

- Every SAP namespace of cell/stack N ends in `-N`; no unsuffixed special case in the multi-EIC pipelines.
- Topology A: `cellCount` param, default `"2"`; with `"1"` every `cell2-*` task is skipped via `when: [{input: "$(params.cellCount)", operator: in, values: ["2"]}]`.
- All cells: three test rounds as today; one shared `eic-auth-secret`; host `eic-N.<ingress domain>`; gateway namespace `istio-gateways-N`; ConfigMaps `cluster-info-hcp-<cluster>-N` and `route-info-hcp-<cluster>-N`.
- Postgres deployed once, unchanged; Redis/Valkey per cell with instance `eic-N` (namespace = today's default namespace + `-eic-N`).
- Topology B per stack N: `edgelm-N`; `istio-system-sap-edge-N` / Istio `sap-mesh-istio-N` / discovery `sap-edge-mesh-N`; `istio.io/rev` = active revision read from the cluster; kubeconfig Secret `edgelm-kubeconfig-generated-<cluster>-N`; S3 folders `elm-N/`, `edge-icell-N/`; prefix `restricted-resources/pr{{ pull_request_number }}-multi-stack/`; cluster `hcp-multistack-pr{{ pull_request_number }}`.
- Every new task param defaults to today's behavior (used by `hcp-kubevirt-validation`, `hcp-cloud-connector-validation`, `hcp-ossm3-validation`, ARO/ROSA).
- ApprovalTasks never carry `when`; credentials never appear in approval descriptions or task results.
- Embedded scripts: `#!/usr/bin/env bash` + `set -euo pipefail`, shellcheck-clean at default severity (`shellcheck -x`), guard empty arrays under `set -u`.
- New/changed files carry SPDX headers (REUSE); `npm run cspell` clean (add words to `.config/cspell-words.txt`); `yamllint -c .config/yamllint.yml` clean.
- Commits signed off (`git commit -s`), conventional-commit style.

## Review Focus

- `cellCount=1`: no `cell2-*` task runs and nothing fails because `istio-gateways-2` is absent — the wiring checker's cell-gate rule (Task 1) is enforced on the topology A pipeline (Task 9).
- Other pipelines unchanged: every shared-task test has a `defaults` case asserting today's names (`cluster-info-hcp-<cluster>`, `route-info-hcp-<cluster>`, `eic.` host, SA `edgelm` in `edgelm`, workspace file `edgelm-kubeconfig`, `sap-eic-external-redis`), and the wiring checker runs over every pipeline in `.tekton/pipelines/`.
- Parallel per-stack kubeconfig tasks must not overwrite each other's workspace file or Secret (Task 6 test `two_stacks_distinct_outputs`).
- Two gateways with the same service name: the endpoint-slice fix must patch only the selected gateway's slices (Task 4 test `namespace_selects_one_gateway`).
- Re-runs: mesh labelling must be idempotent when `istio-injection` was already stripped and revision labels already set (Task 8 test `rerun_is_idempotent`).

---

## File Structure

| Path | Responsibility |
|---|---|
| `hack/tekton-tests/extract_task_script.py` | Print a Task step's script as runnable bash with Tekton variables substituted and chosen line ranges dropped |
| `hack/tekton-tests/fake-bin/oc` (+ `kubectl` symlink) | Rule-driven fake CLI: logs every call, answers from a rules file |
| `hack/tekton-tests/lib.sh` | Test helpers: `run_task`, `assert_called`, `assert_not_called`, `assert_file_contains`, `fail` |
| `hack/tekton-tests/check_pipeline.py` | Static wiring checker for pipelines and PaC run files |
| `hack/tekton-tests/run.sh` | Runs all `test_*.sh` and the checker; exit non-zero on any failure |
| `hack/tekton-tests/test_*.sh` | One file per task under test |
| `hack/tekton-tests/fixtures/` | Broken pipeline/run fixtures for checker self-tests |
| `.tekton/tasks/*` | Changed shared tasks (Tasks 2–7) and two new tasks (Task 8) |
| `.tekton/pipelines/hcp-ossm3-dedicated-validation-pipeline.yaml` | Topology A per-cell rework (Task 9) |
| `.tekton/pipelines/hcp-ossm3-multi-stack-validation-pipeline.yaml` | New topology B pipeline (Task 10) |
| `.tekton/*-run.yaml`, `.tekton-examples/hcp-ossm3-dedicated*-run.yaml` | Run files (Tasks 9–11) |
| `docs/multi-eic-restricted-resources-convention.md` | Updated norm (Task 11) |

---

### Task 1: Test harness and pipeline wiring checker

**Files:**
- Create: `hack/tekton-tests/extract_task_script.py`, `hack/tekton-tests/fake-bin/oc`, `hack/tekton-tests/fake-bin/kubectl` (symlink to `oc`), `hack/tekton-tests/lib.sh`, `hack/tekton-tests/check_pipeline.py`, `hack/tekton-tests/run.sh`, `hack/tekton-tests/test_harness.sh`, `hack/tekton-tests/test_download_and_apply_rbac.sh`, `hack/tekton-tests/fixtures/broken-pipeline.yaml`, `hack/tekton-tests/fixtures/broken-run.yaml`, `hack/tekton-tests/README.md`

**Interfaces:**
- Produces:
  - `extract_task_script.py TASK_YAML [--step NAME] [--param K=V]... [--results-dir DIR] [--workspace-dir DIR] [--namespace NS] [--drop 'START_LITERAL' 'END_LITERAL']... [--from 'LITERAL'] [--to 'LITERAL']` → stdout bash. Substitutes `$(params.K)` (unset params → the Task default, required params without `--param` → error), `$(results.R.path)` → `DIR/R`, `$(workspaces.W.path)` → workspace dir, `$(context.taskRun.namespace)` → NS. `--drop` removes the inclusive line range from the first line containing START to the next line containing END (repeatable; used to drop tool installs). `--from`/`--to` keep only the range starting at the line containing FROM up to (excluding) the line containing TO, but always keep every line before the first `# Install`/`echo "📦 Installing` line (the variable header).
  - `fake-bin/oc`: env `FAKE_OC_LOG` (append `"$*"` per call), `FAKE_OC_RULES` (file; lines `GLOB<TAB>EXIT<TAB>STDOUT`, `\n` in STDOUT expanded; first glob matching the full argument string wins; no match → exit 0, no output), `FAKE_OC_STDIN_DIR` (when set, the stdin of every `apply -f -` / `create -f -` call is saved as `NNN.yaml`, numbered in call order).
  - `lib.sh`: `run_task TASK_YAML [extract args...]` (extracts to a temp file, runs with `PATH=fake-bin:$PATH`, stores stdout+stderr in `$TASK_OUT`, exit code in `$TASK_RC`); `assert_called PATTERN` / `assert_not_called PATTERN` (grep -E on `$FAKE_OC_LOG`); `assert_file_contains FILE PATTERN`; `assert_rc N`; `fail MSG`.
  - `check_pipeline.py [--cell-gate PIPELINE_NAME:PARAM:VALUE]... FILES...` → exit 1 with one line per violation. Rules: runAfter targets exist; `$(params.X)` exists in pipeline params; `$(tasks.T.results.R)` → T exists and its Task declares R; `taskRef.name` resolves to a `metadata.name` under `.tekton/tasks/` (ApprovalTask kind and inline `taskSpec` allowed); every passed param is declared by the Task and every Task param without default is passed; Task workspaces are bound; ApprovalTasks have no `when`; with `--cell-gate P:cellCount:2`, every task of pipeline P whose name starts `cell2-` has a `when` with input `$(params.cellCount)`, operator `in`, values `["2"]`; run files (kind PipelineRun): `pipelineRef.name` matches a pipeline in FILES, params ⊆ pipeline params, required pipeline params supplied.
  - `run.sh`: runs every `hack/tekton-tests/test_*.sh`, then `check_pipeline.py --cell-gate hcp-ossm3-dedicated-validation:cellCount:2 .tekton/pipelines/*.yaml .tekton/*-run.yaml`.

- [ ] **Step 1: Write the checker self-tests and harness self-test**

`test_harness.sh` asserts:
- `check_pipeline.py fixtures/broken-pipeline.yaml fixtures/broken-run.yaml` exits 1 and reports each seeded violation: unknown runAfter `no-such-task`, undeclared param `$(params.missing)`, unknown result `$(tasks.a.results.nope)`, param `bogus` not declared by the referenced task, ApprovalTask with `when`, a `cell2-x` task without the cell gate (run with `--cell-gate broken:cellCount:2`), run file param `unknownParam`.
- `extract_task_script.py .tekton/tasks/ossm3-prepare-restricted-resources-prefix-task.yaml --param components='elm edge-icell-1'` output contains `COMPONENTS="elm edge-icell-1"` and no `$(params.`.
- fake `oc`: a rule `get ns*<TAB>0<TAB>a\nb` makes `oc get ns -l x` print two lines and logs the call.

`test_download_and_apply_rbac.sh` (regression for the merged Step 2): build zips under a temp `DOWNLOAD_DIR` for `elm-1/ elm-2/ edge-icell-1/ edge-icell-2/ edge-icell-10/` (versions 1.58.0 and 1.62.0-rc.1 in `elm-1/`), run the section `--from '# Step 2:' --to '# Step 3:'` with `DOWNLOAD_DIR`/`RBAC_DIR` pointing at temp dirs, list `find RBAC_DIR -mindepth 1 -maxdepth 1 -type d | sort -V`, assert exact order `00_elm-1_Edge_Lifecycle_Management`, `00_elm-2_…`, `20_edge-icell-1_…`, `20_edge-icell-2_…`, `20_edge-icell-10_…`, and that `elm-1` extracted the `1.62.0-rc.1` zip.

- [ ] **Step 2: Run them to verify they fail**

Run: `bash hack/tekton-tests/test_harness.sh`
Expected: FAIL (`extract_task_script.py: No such file`)

- [ ] **Step 3: Implement the five harness files**

`run_task` runs the extracted script with `bash`, never sourcing it. Keep `lib.sh`, `run.sh`, tests and `fake-bin/oc` shellcheck-clean (CI lints every `*.sh`; `fake-bin/oc` has no extension but keep it clean too).

- [ ] **Step 4: Run the harness, then the checker over the real repo**

Run: `bash hack/tekton-tests/run.sh`
Expected: all tests PASS; the checker reports no violation. If the checker reports violations in pipelines this plan does not touch, record them in an explicit allowlist inside `check_pipeline.py` (pipeline name + rule + item, with a comment) instead of changing those pipelines.

- [ ] **Step 5: Lint and commit**

Run: `.venv/bin/shellcheck -x hack/tekton-tests/*.sh hack/tekton-tests/fake-bin/oc && .venv/bin/reuse lint && npm run cspell`
Expected: clean (the gitignored `rosa/terraform/create-approvers-simple.sh` findings are local-only).

```bash
git add hack/tekton-tests .config/cspell-words.txt docs/superpowers
git commit -s -m "test(tekton): add local harness for embedded task scripts and pipeline wiring"
```

---

### Task 2: Topology A — discovery label on every SAP namespace

**Files:**
- Modify: `.tekton/tasks/ossm3-configure-dedicated-mesh-task.yaml` (block "Label application namespaces to join the dedicated mesh")
- Test: `hack/tekton-tests/test_configure_dedicated_mesh.sh`

**Interfaces:**
- Consumes: Task 1 harness.
- Produces: unchanged task interface.

- [ ] **Step 1: Write the failing test** `secrets_gets_discovery_not_rev`: rules — `get namespace -l edgelm.sap.com/product=edgelm*` → `edgelm\nedge-icell-1\nedge-icell-secrets-1\nistio-gateways-1`; run the section from `# --- Label the dedicated control plane namespace` to `# --- Create ServiceEntry`. Assert called `label namespace edge-icell-secrets-1 istio-discovery=sap-edge-mesh --overwrite`; assert not called `label namespace edge-icell-secrets-1 .*istio.io/rev`; assert called for `edgelm`, `edge-icell-1`, `istio-gateways-1`. Case `none_found_fails`: empty namespace list → `$TASK_RC` non-zero and output contains `No namespaces labeled edgelm.sap.com/product=edgelm`.
- [ ] **Step 2: Run it to verify it fails** — `bash hack/tekton-tests/test_configure_dedicated_mesh.sh` → FAIL (secrets namespace not labelled).
- [ ] **Step 3: Implement** — select `APP_NAMESPACES` by `edgelm.sap.com/product=edgelm` (not `istio.io/rev`), label each `istio-discovery=${DISCOVERY_LABEL}` only; update the comment to cite KBA 7131840 (discovery on all SAP namespaces, injection workload-only, set by prepare-namespaces).
- [ ] **Step 4: Run it to verify it passes** — same command → PASS; `bash hack/tekton-tests/run.sh` → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "fix(ossm3-dedicated-mesh): label secrets namespace for discovery per KBA 7131840"`

---

### Task 3: Gateway-aware ConfigMap and Route tasks

**Files:**
- Modify: `.tekton/tasks/hcp-validate-and-create-configmap-task.yaml`, `.tekton/tasks/hcp-create-eic-route-task.yaml`
- Test: `hack/tekton-tests/test_configmap_and_route.sh`

**Interfaces:**
- Produces (new params, all optional):
  - `hcp-validate-and-create-configmap`: `gatewayNamespace` (default `""` = today's search order istio-system → istio-gateways → all namespaces, also for the HPA lookup), `hostPrefix` (default `"eic"`), `configMapName` (default `""` → `cluster-info-hcp-<cluster>`).
  - `hcp-create-eic-route`: `gatewayNamespace` (default `""` = today's search), `hostPrefix` (default `"eic"`), `routeConfigMapName` (default `""` → `route-info-hcp-<cluster>`). Route object name stays `eic-https-route` (unique per gateway namespace).
  - With `gatewayNamespace` set, both tasks look **only** in that namespace (no fallback search) and fail with a clear message if `istio-ingressgateway` is absent there.

- [ ] **Step 1: Write the failing tests** (rules give ingress domain `apps.test.example`, LB IP `10.0.0.5` for the namespace in question, and an `istio-ingressgateway` in both `istio-gateways-1` and `istio-gateways-2`):
  - `configmap_defaults`: no new params → called `create configmap cluster-info-hcp-c1 --from-literal=host=eic.apps.test.example`.
  - `configmap_cell2`: `gatewayNamespace=istio-gateways-2 hostPrefix=eic-2 configMapName=cluster-info-hcp-c1-2` → called `get svc istio-ingressgateway -n istio-gateways-2`, `create configmap cluster-info-hcp-c1-2 --from-literal=host=eic-2.apps.test.example --from-literal=ingressIP=10.0.0.5`; not called `-n istio-gateways-1`; HPA lookup only in `istio-gateways-2`.
  - `route_defaults`: captured `apply -f -` stdin (`FAKE_OC_STDIN_DIR`) contains the Route with `host: eic.apps.test.example` and ConfigMap `route-info-hcp-c1`.
  - `route_cell2`: `gatewayNamespace=istio-gateways-2 hostPrefix=eic-2 routeConfigMapName=route-info-hcp-c1-2` → Route `namespace: istio-gateways-2`, `host: eic-2.apps.test.example`; ConfigMap `route-info-hcp-c1-2` with `host: "eic-2.apps.test.example"`.
  - `route_missing_gateway_fails`: `gatewayNamespace=istio-gateways-3` (absent) → non-zero, message names `istio-gateways-3`.
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_configmap_and_route.sh` → FAIL (unknown param `gatewayNamespace` from the extractor).
- [ ] **Step 3: Implement the params** as specified in Interfaces.
- [ ] **Step 4: Run to verify they pass** — same command and `bash hack/tekton-tests/run.sh` → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(hcp-tasks): per-gateway host, namespace and ConfigMap for EIC tests"`

---

### Task 4: Endpoint-slice fix selects one gateway

**Files:**
- Modify: `.tekton/tasks/hcp-fix-endpointslice-task.yaml`
- Test: `hack/tekton-tests/test_fix_endpointslice.sh`

**Interfaces:**
- Produces: new optional param `guestServiceNamespace` (default `""` = today's selector `cluster.x-k8s.io/tenant-service-name=<svc>`); when set the selector becomes `cluster.x-k8s.io/tenant-service-name=<svc>,cluster.x-k8s.io/tenant-service-namespace=<ns>`.

- [ ] **Step 1: Write the failing tests** — `defaults_selector`: called `get svc -n clusters-c1 -l cluster.x-k8s.io/tenant-service-name=istio-ingressgateway`. `namespace_selects_one_gateway`: `guestServiceNamespace=istio-gateways-2`; rules return management service `svc-gw2` only for the selector containing `tenant-service-namespace=istio-gateways-2`; assert all `endpointslice` calls reference `svc-gw2`, none reference `svc-gw1`.
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_fix_endpointslice.sh` → FAIL.
- [ ] **Step 3: Implement** the param and selector.
- [ ] **Step 4: Run to verify they pass** — same command → PASS.
- [ ] **Step 5: Manual check to record in the commit body** — on any running HCP KubeVirt cluster with a LoadBalancer service, `oc get svc -n <clusters-ns>-<cluster> --show-labels | grep tenant-service` must show `cluster.x-k8s.io/tenant-service-namespace`. If the label is absent, stop and report (the selector needs a different discriminator).
- [ ] **Step 6: Commit** — `git commit -s -m "feat(hcp-fix-endpointslice): select gateway by tenant service namespace"`

---

### Task 5: Instance-aware Redis/Valkey and access summary

**Files:**
- Modify: `.tekton/tasks/hcp-deploy-redis-task.yaml`, `.tekton/tasks/hcp-deploy-valkey-task.yaml`, `.tekton/tasks/hcp-get-all-accesses-task.yaml`
- Test: `hack/tekton-tests/test_backing_service_instance.sh`

**Interfaces:**
- Produces: new optional param `instance` (default `""`) on all three tasks. Namespace rule (same as the scripts' `--instance`): `<default namespace>-<instance>`, where the default is `sap-eic-external-redis` (redis; or the `redisNamespace` param), `sap-eic-external-valkey` (valkey-standalone), `sap-eic-external-valkey-cluster` (valkey-cluster). Results keep their names; hosts reflect the instance namespace. `hcp-get-all-accesses` keeps Postgres at `sap-eic-external-postgres` (shared).

- [ ] **Step 1: Write the failing tests** — run each task's section from the line after the hosted-cluster connection to the end, with `deploy_redis.sh`/`deploy_valkey.sh` replaced by a stub in a temp workspace that logs its args:
  - `redis_defaults`: stub called with `-n sap-eic-external-redis`; result `redis-host` ends `.sap-eic-external-redis.svc.cluster.local`.
  - `redis_instance`: `instance=eic-2` → `-n sap-eic-external-redis-eic-2`; host in that namespace.
  - `valkey_cluster_instance`: `datastoreType=valkey-cluster instance=eic-1` → `-n sap-eic-external-valkey-cluster-eic-1`.
  - `accesses_instance`: `datastoreType=redis instance=eic-2` → oc queries Redis in `sap-eic-external-redis-eic-2` and Postgres in `sap-eic-external-postgres`.
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_backing_service_instance.sh` → FAIL.
- [ ] **Step 3: Implement** the param and namespace rule in the three tasks.
- [ ] **Step 4: Run to verify they pass** — same command → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(hcp-tasks): optional EIC instance for Redis/Valkey and access summary"`

---

### Task 6: Kubeconfig per ELM namespace

**Files:**
- Modify: `.tekton/tasks/ossm3-generate-sa-based-kubeconfig-task.yaml`
- Test: `hack/tekton-tests/test_generate_kubeconfig.sh`

**Interfaces:**
- Produces: new optional params `elmNamespace` (default `"edgelm"`), `generatedSecretName` (default `""` → `edgelm-kubeconfig-generated-<cluster>`). SA name = `.subjects[?(@.kind=="ServiceAccount")].name` of RoleBinding `rb-edgelm-manage` in `elmNamespace` whose subject namespace is `elmNamespace`; fallback `edgelm` with a warning. Token Secret `edgelm-kubeconfig-token` in `elmNamespace`. Workspace file `$(workspaces.source.path)/<elmNamespace>-kubeconfig` (default stays `edgelm-kubeconfig`). Result `kubeconfig-info` mentions SA, namespace and Secret.

- [ ] **Step 1: Write the failing tests** — `defaults`: called `create sa edgelm -n edgelm`; Secret applied named `edgelm-kubeconfig-generated-c1`; workspace file `edgelm-kubeconfig` exists. `stack2`: `elmNamespace=edgelm-2 generatedSecretName=edgelm-kubeconfig-generated-c1-2`, RoleBinding rule returns SA `edgelm` → `create sa edgelm -n edgelm-2`, token Secret in `edgelm-2`, Secret `…-c1-2`, file `edgelm-2-kubeconfig`. `two_stacks_distinct_outputs`: run stack 1 and stack 2 into the same workspace dir → two files and two Secret names, neither overwritten.
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_generate_kubeconfig.sh` → FAIL.
- [ ] **Step 3: Implement** the params (replace every hardcoded `edgelm` namespace/SA in the script with the variables).
- [ ] **Step 4: Run to verify they pass** — same command → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(ossm3-kubeconfig): generate kubeconfig for a given ELM namespace"`

---

### Task 7: Monitoring tasks discover cell namespaces

**Files:**
- Modify: `.tekton/tasks/hcp-enable-monitoring-task.yaml`, `.tekton/tasks/hcp-verify-monitoring-task.yaml`
- Test: `hack/tekton-tests/test_monitoring_discovery.sh`

**Interfaces:**
- Produces: new optional param `discoverNamespaces` (default `"false"` = today's `NAMESPACES=("edge-icell" "edge-icell-services" "edgelm")`). With `"true"`: namespaces labelled `edgelm.sap.com/product=edgelm` whose role (name with trailing `-<digits>` stripped) is `edgelm`, `edge-icell` or `edge-icell-services`, sorted with `sort -V`.

- [ ] **Step 1: Write the failing tests** — `defaults_fixed_list`: NetworkPolicies applied for exactly `edge-icell`, `edge-icell-services`, `edgelm`. `discover_two_stacks`: product namespaces `edgelm-1 edgelm-2 edge-icell-1 edge-icell-secrets-1 edge-icell-services-1 edge-icell-2 edge-icell-ela-2 istio-gateways-1` → policies for `edgelm-1 edgelm-2 edge-icell-1 edge-icell-2 edge-icell-services-1` only. Same two cases for verify-monitoring (ServiceMonitor queries per namespace).
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_monitoring_discovery.sh` → FAIL.
- [ ] **Step 3: Implement** the param in both tasks.
- [ ] **Step 4: Run to verify they pass** — same command → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(hcp-monitoring): optional label-based discovery of EIC namespaces"`

---

### Task 8: Topology B mesh and namespace tasks

**Files:**
- Create: `.tekton/tasks/ossm3-configure-multi-stack-mesh-task.yaml`, `.tekton/tasks/ossm3-prepare-namespaces-multi-stack-task.yaml`
- Test: `hack/tekton-tests/test_multi_stack.sh`

**Interfaces:**
- Consumes: Task 1 harness.
- Produces:
  - Both tasks: params `hostedClusterName` (required), `hostedClusterNamespace` (default `clusters`), `hubKubeconfigSecretName` (default `""`); workspace `source`; same hub/hosted kubeconfig handling as `ossm3-configure-dedicated-mesh`. Result `stacks` (space-separated stack indices, e.g. `1 2`).
  - `ossm3-configure-multi-stack-mesh`: extra param `proxySecretName` (default `""`, same semantics as `ossm3-configure-dedicated-mesh`).
  - Identical stack discovery in both (copy, keep in sync): SAP namespaces = `oc get namespace -l edgelm.sap.com/product=edgelm`; stack N = names matching `-N$`; fail (non-zero, message naming the offender) when: a SAP namespace has no `-<digits>` suffix; a stack lacks `edgelm-N`; a stack's namespaces carry more than one `edgelm.sap.com/edge-node-id`; two stacks share an `edge-node-id`.
  - Revision lookup (prepare task): `oc get istio sap-mesh-istio-N -n istio-system-sap-edge-N -o jsonpath='{.status.activeRevisionName}'`; if empty, the single `istiorevisions` entry in that namespace; fail if neither yields one.

- [ ] **Step 1: Write the failing tests** (rules: namespaces with `edge-node-id` labels `A` for `*-1`, `B` for `*-2`; `istio-injection` = `enabled` on all but secrets; Istio status `activeRevisionName` = `sap-mesh-istio-1` / `sap-mesh-istio-2-v1-24`):
  - `mesh_creates_one_control_plane_per_stack`: applied Istio manifests (captured stdin) contain `name: sap-mesh-istio-1`, `namespace: istio-system-sap-edge-1`, `istio-discovery: sap-edge-mesh-1`, and the `-2` equivalents; IstioCNI applied once; called `wait --for=condition=Ready istio/sap-mesh-istio-2 -n istio-system-sap-edge-2`; result `stacks` = `1 2`.
  - `mesh_proxy_serviceentry_per_stack`: proxy rules set → ServiceEntry applied in `edgelm-1` and `edgelm-2`.
  - `validation_unsuffixed_fails`, `validation_missing_elm_fails`, `validation_mixed_node_ids_fails`, `validation_shared_node_id_fails`: each non-zero with a message naming the namespace/stack.
  - `prepare_labels_per_stack`: called `label namespace edge-icell-2 istio.io/rev=sap-mesh-istio-2-v1-24 --overwrite`; `label namespace edge-icell-secrets-1 istio-discovery=sap-edge-mesh-1 --overwrite`; never `istio.io/rev` on `edge-icell-secrets-*`; `istio-injection-` removed on every SAP namespace; SCC for `edge-icell-ela-2` = `100000/1000` and `100002/1000`, for `edgelm-1` supplemental `67000/1000` only.
  - `rerun_is_idempotent`: namespaces already without `istio-injection` but with `istio.io/rev=<rev N>` → same rev labels applied again, no failure.
  - `revision_fallback_to_istiorevisions`: empty status → uses the `istiorevisions` name.
- [ ] **Step 2: Run to verify they fail** — `bash hack/tekton-tests/test_multi_stack.sh` → FAIL (task files missing).
- [ ] **Step 3: Implement both tasks** per Interfaces; reuse the control-plane manifest (incl. DNS-capture proxy metadata) and SCC table from `ossm3-configure-dedicated-mesh` / `ossm3-prepare-namespaces-dedicated`; end the prepare task with `oc get namespaces -l edgelm.sap.com/product=edgelm -L edgelm.sap.com/edge-node-id,istio-discovery,istio.io/rev,istio-injection`; configure task also prints every Istio's discovery selectors and fails if two Istio resources select the same `istio-discovery` value.
- [ ] **Step 4: Run to verify they pass** — same command and `bash hack/tekton-tests/run.sh` → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(ossm3): dedicated mesh and namespace overlay per Edge Node (topology B)"`

---

### Task 9: Topology A pipeline — per-cell backing services and validation

**Files:**
- Modify: `.tekton/pipelines/hcp-ossm3-dedicated-validation-pipeline.yaml`, `.tekton/hcp-ossm3-dedicated-validation-run.yaml`
- Test: `hack/tekton-tests/run.sh` (wiring checker with the cell gate)

**Interfaces:**
- Consumes: params from Tasks 3–7.
- Produces: per-cell task names used by Task 10 (same names there): `cell{N}-deploy-redis`, `cell{N}-deploy-valkey`, `cell{N}-get-all-accesses`, `cell{N}-validate-and-create-configmap`, `cell{N}-fix-endpointslice`, `cell{N}-create-eic-route`, `cell{N}-test-httpbinipfilter`, `cell{N}-test-http-test1`, `cell{N}-test-http-testelster`, `cell{N}-test-slvredis`, `cell{N}-test-ratelimit-slvredis`, `cell{N}-cooldown-after-round1`, the same five tests and cooldown with `-round2`, and the five tests with `-route`.

- [ ] **Step 1: Add the failing gate** — run `bash hack/tekton-tests/run.sh` after adding the pipeline param `cellCount` (`default: "2"`, description: number of EIC cells, `1` skips every `cell2-*` task) and one placeholder `cell2-validate-and-create-configmap` without `when` → Expected: FAIL on the cell-gate rule. Remove the placeholder.
- [ ] **Step 2: Restructure the pipeline**
  - Keep `deploy-postgres` as is. Replace `deploy-redis` / `deploy-valkey` / `get-all-accesses` with `cell{N}-…` (`instance: eic-N`, existing `when` on `datastoreType` plus the cell gate for N=2). `approval-elm-eic-iflow-deployed` runs after both cells' `get-all-accesses` and `enable-monitoring`; its description lists per cell: EIC host `eic-N.<ingress domain>`, gateway `istio-gateways-N`, Redis/Valkey namespace, shared Postgres; ELM checklist (one Edge Node, deploy EIC N with host `eic-N…` and its Redis/Valkey); label-cleanup hint stays `oc label namespace -l edgelm.sap.com/product=edgelm istio-injection-`.
  - `enable-monitoring` / `verify-monitoring`: `discoverNamespaces: "true"`.
  - Per cell after the approval: `cell{N}-validate-and-create-configmap` (`gatewayNamespace: istio-gateways-N`, `hostPrefix: eic-N`, `configMapName: cluster-info-hcp-$(params.hostedClusterName)-N`) → `cell{N}-fix-endpointslice` (`guestServiceNamespace: istio-gateways-N`) → `cell{N}-create-eic-route` (`gatewayNamespace`, `hostPrefix`, `routeConfigMapName: route-info-hcp-$(params.hostedClusterName)-N`) → cell N tests for round 1 against `cluster-info-hcp-…-N`, keeping today's `startDelay` values, `when` on `testHttpbinipfilter`/`testSlvredis`, and the rate-limit → cooldown chain per cell.
  - `approval-second-test-round` and `approval-route-test-round` run after both cells' round tests and cooldowns; their descriptions name both cells. Round 2 tests mirror round 1 per cell; Route-round tests use `route-info-hcp-…-N` and `publicDNS: "true"` as today.
  - `update-jira-test-results` runs after both cells' Route-round tests; its comment lists both cells.
  - Every `cell2-*` task carries `when: [{input: "$(params.cellCount)", operator: in, values: ["2"]}]` in addition to its existing conditions.
- [ ] **Step 3: Run file** — `.tekton/hcp-ossm3-dedicated-validation-run.yaml`: add `cellCount: "2"` next to `restrictedResourcesComponents`.
- [ ] **Step 4: Verify** — `bash hack/tekton-tests/run.sh` → PASS (no wiring violation, cell gate satisfied); `.venv/bin/yamllint -c .config/yamllint.yml .tekton/pipelines/hcp-ossm3-dedicated-validation-pipeline.yaml .tekton/hcp-ossm3-dedicated-validation-run.yaml` → clean; `grep -c -- '- name: cell1-'` and `grep -c -- '- name: cell2-'` on the pipeline print the same number.
- [ ] **Step 5: Commit** — `git commit -s -m "feat(hcp-ossm3-dedicated): per-cell Redis/Valkey, routes and tests for two EIC cells"`

---

### Task 10: Topology B pipeline and run file

**Files:**
- Create: `.tekton/pipelines/hcp-ossm3-multi-stack-validation-pipeline.yaml`, `.tekton/hcp-ossm3-multi-stack-validation-run.yaml`
- Test: `hack/tekton-tests/run.sh`

**Interfaces:**
- Consumes: Task 8 tasks; Task 6 params; Task 9 per-cell names and blocks.

- [ ] **Step 1: Write the failing check** — add the run file first (copy of the dedicated run with `pipelineRef: hcp-ossm3-multi-stack-validation-pipeline`, `generateName: hcp-ossm3-multistack-pr{{ pull_request_number }}-`, `hostedClusterName: hcp-multistack-pr{{ pull_request_number }}`, `s3Prefix: restricted-resources/pr{{ pull_request_number }}-multi-stack/`, `restrictedResourcesComponents: elm-1 edge-icell-1 elm-2 edge-icell-2`, no `cellCount`). Run `bash hack/tekton-tests/run.sh` → Expected: FAIL (`pipelineRef` has no pipeline).
- [ ] **Step 2: Create the pipeline** from the topology A pipeline after Task 9:
  - `metadata.name: hcp-ossm3-multi-stack-validation-pipeline`; drop param `cellCount` and every cell gate (both stacks always run).
  - Replace `prepare-namespaces` → `configure-mesh` → `generate-sa-based-kubeconfig` with `configure-multi-stack-mesh` (after `apply-rbac`, `proxySecretName: $(params.hubClusterName)-proxy-config`) → `prepare-namespaces-multi-stack` → `stack1-generate-sa-based-kubeconfig` and `stack2-generate-sa-based-kubeconfig` in parallel (`elmNamespace: edgelm-N`, `generatedSecretName: edgelm-kubeconfig-generated-$(params.hostedClusterName)-N`); backing services and monitoring run after both kubeconfig tasks.
  - Approval texts: per stack the ELM namespace, kubeconfig Secret, mesh `istio-system-sap-edge-N/sap-mesh-istio-N`, host `eic-N…`, Redis/Valkey namespace; ELM checklist registers **two** Edge Nodes, each with its own kubeconfig ("Restricted Access" checked), and deploys EIC N on Edge Node N; label-cleanup hint per Edge Node `oc label namespace -l edgelm.sap.com/edge-node-id=<id> istio-injection-`. Mention minimum releases ELM 1.64 / EIC 8.48 in the upload gate text.
  - Jira comment and descriptions say "multi-stack (2 Edge Nodes, dedicated mesh each)".
- [ ] **Step 3: Verify** — `bash hack/tekton-tests/run.sh` → PASS; yamllint clean on both files; `grep -n 'cellCount' …multi-stack…` → no match.
- [ ] **Step 4: Commit** — `git commit -s -m "feat(tekton): add topology B multi-stack validation pipeline"`

---

### Task 11: Examples and convention doc

**Files:**
- Modify: `.tekton-examples/hcp-ossm3-dedicated-validation-run.yaml`, `.tekton-examples/hcp-ossm3-dedicated-proxy-validation-run.yaml`, `docs/multi-eic-restricted-resources-convention.md`, `.config/cspell-words.txt`

- [ ] **Step 1: Examples** — both dedicated examples: `s3Prefix: restricted-resources/pr{{ pull_request_number }}/`, `restrictedResourcesComponents: elm edge-icell-1`, `cellCount: "1"`, header comment explains the `-N` naming and the upload gate.
- [ ] **Step 2: Convention doc** — Status (A: implemented incl. per-cell validation; B: implemented as `hcp-ossm3-multi-stack-validation`); drop the "downstream remains single-cell" scope text; naming table gains `edgelm-N` for topology B; S3 layout shows A (`elm/ edge-icell-N/`) and B (`elm-N/ edge-icell-N/`, `pr<N>-multi-stack/`); backing services (shared Postgres, Redis/Valkey per cell); secrets namespace gets the discovery label; Topology B section describes the two new tasks; link the spec.
- [ ] **Step 3: Verify** — `bash hack/tekton-tests/run.sh && npm run cspell && .venv/bin/reuse lint && .venv/bin/yamllint -c .config/yamllint.yml .tekton-examples/hcp-ossm3-dedicated*-run.yaml` → all clean (checker also covers `.tekton-examples/*-run.yaml` when passed explicitly: `python3 hack/tekton-tests/check_pipeline.py .tekton/pipelines/*.yaml .tekton-examples/hcp-ossm3-dedicated*-run.yaml` → PASS).
- [ ] **Step 4: Commit** — `git commit -s -m "docs: multi-EIC convention and examples for per-cell and topology B"`

---

## After all tasks

- [ ] `bash hack/tekton-tests/run.sh`, `npm run cspell`, `.venv/bin/reuse lint`, `.venv/bin/yamllint -c .config/yamllint.yml .` all clean.
- [ ] Ask the user before pushing: the push triggers both PaC runs on PR #161 (two hosted clusters).
