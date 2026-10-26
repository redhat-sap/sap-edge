<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
cspell:words Containerfile ELMB PWDEBUG SAPCAR bsdutils portforward promisified redirectreference serviceaccounts subjectaccessreviews subresource urandom
-->

# ROKS ELM Browser Automation Implementation Plan (Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two-pass restricted-resources apply in the ROKS pipeline, plus a
Route-accessible, Playwright-driven browser task for ROKS with the S3 handoff,
`elm` CLI and `elm init`, milestone waits, and the deploy/teardown flow — with
the SAP screen steps behind a fixed interface.

**Architecture:** Bash/Tekton for the pipeline side (archive old zips, wait
for zips, apply twice, per-run Secret access). Node.js modules in
`hack/sap-browser/` for the browser side, reusing the existing helper's
display/noVNC/session machinery; a new ROKS entry point (`roks-pipeline.mjs`)
runs behind an OAuth-proxy sidecar exposed by a per-run Route. The SAP screen
steps live in `elm-pages.mjs`; in this plan every step throws "not mapped
yet", so `auto` mode hands over to the user at once. **Plan B** (written after
the user records the walkthrough with `sapBrowserMode: inspect`, which this
plan makes possible) fills `elm-pages.mjs`.

**Tech Stack:** Tekton v1 / OpenShift Pipelines, UBI9 bash, AWS CLI v2 against
the ODF OBC bucket, Node.js 24 (built-ins only, no new npm deps), Playwright
1.64.1 (already in `package.json`), OpenShift Route + OAuth proxy.

**Spec:** `docs/superpowers/specs/2026-10-26-roks-elm-browser-automation-design.md`

## Global Constraints

- Tekton v1; embedded scripts are UBI9 bash with `set -euo pipefail`, shellcheck-clean at default severity (`shellcheck -x`, info level included); standalone `*.sh` are linted by CI.
- SPDX header on every new file (copy the header style of a neighboring file of the same type).
- `npm run cspell` clean (add genuine new words to `.config/cspell.yml`, never disable checks).
- `bash hack/tekton-tests/run.sh` and `npm run sap:browser:test` pass after every task.
- No behavior change for HCP: `hcp-sap-browser` task, `hack/sap-browser/pipeline.mjs`, `inputs.mjs` exports, `runner-rbac.yaml` and every HCP pipeline keep working unchanged; new params on shared tasks default to today's behavior.
- Credentials (database passwords, registry API key, context password, kubeconfigs, `context.cfg`, HMAC keys) never in logs, task results, approval text, traces or screenshots; child processes get an explicit minimal `env`, never `process.env`.
- The browser never reads the `kubeconfig` key of `eic-credentials-roks-<cluster>` (cluster-admin); the only kubeconfig it uploads is `edgelm-kubeconfig-generated-<cluster>`.
- The ROKS browser task always exits 0; its outcome is the result `outcome`.
- Per-run folder: `restricted-resources/<clusterName>/` with components `elm` and `edge-icell`; `elm` CLI under `tools/elm/` in the same bucket.
- Runner service account for ROKS: `roks-sap-browser-runner` (not `sap-browser-runner`, whose HCP Role grants namespace-wide `get secrets`).
- Commit after each task with `git commit -s` (DCO). Do not push: a push to the PR starts a ROKS run.

## Review Focus

1. OAuth proxy refuses the login (redirect reference or access check wrong) — users with `pods/portforward` in the pipeline namespace must get through. Pinned by Task 7 (exact SA annotation) and Task 10 (exact `--openshift-sar` JSON).
2. Second apply on EIC namespaces that `prepare-namespaces` already created — the bundle script must adopt them (no CONFLICT: they carry no `edge-node-id`) and mesh labels must survive. Pinned by Task 3 (namespace and mesh tasks rerun after `apply-rbac-eic`); first live run verifies.
3. Zips left by an earlier run — never applied. Pinned by Task 1 (archive before markers) and Task 3 (`archiveExisting: "true"` on ROKS only).
4. Browser task dies (bad image, display crash, login timeout, session expiry) — the run continues on the manual path. Pinned by Task 9 (`main` never rejects) and Task 10 (step exits 0, writes `failed`).
5. Credentials reaching child processes or logs (AWS keys in `elm`'s env, password echoed by `elm`). Pinned by Task 6 env and masking tests.

---

### Task 1: Archive earlier zips in the prefix task

**Files:**
- Modify: `.tekton/tasks/ossm3-prepare-restricted-resources-prefix-task.yaml`
- Test: `hack/tekton-tests/test_prepare_prefix_archive.sh`
- Also commit: the spec and this plan (`docs/superpowers/specs/2026-10-26-roks-elm-browser-automation-design.md`, `docs/superpowers/plans/2026-10-26-roks-elm-browser-automation.md`)

**Interfaces:**
- Produces: param `archiveExisting` (string, default `"false"`). When `"true"` and `components` is non-empty, before the marker objects are created, for each component `C`:
  `aws s3 mv s3://<bucket>/<PREFIX><C>/ s3://<bucket>/<PREFIX>archive/<STAMP>/<C>/ --recursive --exclude '*' --include '*.zip'` (through the existing `s3()` wrapper), `STAMP=$(date -u +%Y%m%dT%H%M%SZ)`, one stamp per task run, and print `📦 Archived earlier zips of <C>/ to archive/<STAMP>/<C>/`.

- [ ] **Step 1: Write the failing test** `test_prepare_prefix_archive.sh` in the style of `test_download_and_apply_rbac.sh`: a test-local fake `aws` on `PATH` that appends its argv to a log and prints nothing; extract the script (skip the `dnf`/`curl` install block with `--drop`/`--from`) and run with `--param obcName=x --param s3Prefix=restricted-resources/c1/ --param components="elm edge-icell"`, env `BUCKET_NAME=bkt BUCKET_HOST=h BUCKET_PORT=443`. Cases:
  - `archive_moves_only_zips` (`archiveExisting=true`): log has `s3 mv s3://bkt/restricted-resources/c1/elm/ s3://bkt/restricted-resources/c1/archive/` and the same for `edge-icell/`, each with `--exclude * --include *.zip`; both `mv` lines come before the first `put-object` line.
  - `archive_off_by_default` (param omitted): no `s3 mv` in the log.
  - `archive_skipped_for_flat_prefix` (`archiveExisting=true`, `components=""`): no `s3 mv`.
- [ ] **Step 2:** `bash hack/tekton-tests/test_prepare_prefix_archive.sh` → FAIL (no `mv`).
- [ ] **Step 3:** Implement the param and the archive block in the task.
- [ ] **Step 4:** Test passes; `bash hack/tekton-tests/run.sh` passes.
- [ ] **Step 5:** Commit `feat(tekton): optionally archive earlier zips before an upload` (with the spec and plan).

### Task 2: Task that waits for zips in S3 folders

**Files:**
- Create: `.tekton/tasks/ossm3-wait-for-restricted-resources-task.yaml`
- Test: `hack/tekton-tests/test_wait_for_restricted_resources.sh`

**Interfaces:**
- Produces: Task `ossm3-wait-for-restricted-resources`, params `obcName` (default `sap-eic-restricted-cluster-config-resources`), `s3Prefix` (required), `components` (required, space-separated, non-empty), `instructions` (default `""`), `pollSeconds` (default `"30"`). Env from the OBC Secret/ConfigMap exactly as in the prefix task; installs `unzip` + AWS CLI the same way.
- Behavior: print `instructions` once, then each target `s3://<bucket>/<prefix><C>/`; loop until every component has at least one key ending in `.zip` under it, using `aws s3 ls s3://<bucket>/<prefix><C>/ --recursive` filtered with `awk '$4 ~ /\.zip$/'`; print a `⏳ still waiting for: <components>` line every 10 polls; on success print each found key and exit 0. Empty `components` → `❌` message, exit 1. No own timeout (the PipelineTask timeout applies).

- [ ] **Step 1: Write the failing test** with a fake `aws` whose `s3 ls` output comes from per-folder files in a temp dir, and which counts calls so a file can appear on a later poll (`pollSeconds=0`). Cases:
  - `waits_until_every_folder_has_a_zip`: `elm/` has `restricted-resources-Edge_Lifecycle_Management-1.64.0.zip` from the start, `edge-icell/` gets `restricted-resources-Edge_Integration_Cell-8.48.11.zip` on the 3rd poll → rc 0, output names both keys, `edge-icell` listed ≥ 3 times.
  - `ignores_markers_and_non_zips`: `elm/` lists only the zero-byte marker and `readme.txt` for 2 polls, then a zip → rc 0 only after the zip appears (the fake records the poll count at exit = 3).
  - `rejects_empty_components`: `components=""` → rc ≠ 0, output contains `components`.
  - `prints_instructions_once`: instructions text appears exactly once.
- [ ] **Step 2:** Run → FAIL (task missing).
- [ ] **Step 3:** Write the task.
- [ ] **Step 4:** Test passes; `run.sh` passes.
- [ ] **Step 5:** Commit `feat(tekton): add a task that waits for restricted-resources zips`.

### Task 3: Two-pass apply in the ROKS pipeline (manual path)

**Files:**
- Modify: `.tekton/pipelines/roks-eic-full-test-pipeline.yaml`
- Modify: `.tekton/roks-eic-ossm3-run.yaml`, `.tekton-examples/roks-eic-ossm3-run.yaml` (keep identical; setup comment step 3 only)
- Modify: `.tekton/README.md` (ROKS "Restricted-resources upload" paragraph)
- Test: `hack/tekton-tests/test_roks_two_pass_wiring.sh`

**Interfaces:**
- Consumes: Task 1 `archiveExisting`, Task 2 task.
- Produces (pipeline task names later tasks wire to): `wait-elm-zip`, `apply-rbac-elm`, `wait-eic-zip`, `apply-rbac-eic`, `prepare-namespaces-eic`, `configure-mesh-eic`.

DAG changes (prefix value everywhere: `restricted-resources/$(params.clusterName)/`):
- `prepare-restricted-resources-prefix`: add `archiveExisting: "true"`.
- Delete `approval-upload-restricted-resources`.
- `wait-elm-zip`: runAfter `[prepare-restricted-resources-prefix]`, `components: "elm"`, `instructions`: "Upload the Edge Lifecycle Management restricted-resources zip of Edge Node $(params.clusterName) (ELM: Add Edge Node with restricted access) to the elm/ folder below."
- `apply-rbac` → rename `apply-rbac-elm`: runAfter `[verify-operators, wait-elm-zip]`, `requiredComponents: "elm"`. `prepare-namespaces` runAfter `[apply-rbac-elm]`; `configure-mesh`, `generate-sa-based-kubeconfig` unchanged.
- `wait-eic-zip`: runAfter `[generate-sa-based-kubeconfig]`, `components: "edge-icell"`, `instructions`: "Register Edge Node $(params.clusterName) in ELM with the restricted kubeconfig in Secret edgelm-kubeconfig-generated-$(params.clusterName) (pipeline namespace), deploy Edge Integration Cell, then upload its restricted-resources zip to the edge-icell/ folder below."
- `apply-rbac-eic`: runAfter `[wait-eic-zip]`, `requiredComponents: "edge-icell"`, otherwise as `apply-rbac-elm`.
- `prepare-namespaces-eic` (same task/params as `prepare-namespaces`) runAfter `[apply-rbac-eic]`; `configure-mesh-eic` (same as `configure-mesh`) runAfter `[prepare-namespaces-eic]` — re-applies mesh labels in case the EIC bundle's namespace manifests replaced them.
- `approval-elm-eic-iflow-deployed`: runAfter `[configure-mesh-eic, registry-access]`; description: registration and EIC deployment happened before this gate; approve once EIC is up and the iFlows are deployed.
- Update every remaining reference to `apply-rbac` / the removed gate (comments, descriptions, README).

- [ ] **Step 1: Write the failing test** (python-in-bash like `test_multi_eic_wiring.sh`) asserting: no task `approval-upload-restricted-resources`; prefix task has `archiveExisting == "true"`; each runAfter above (as sets); `requiredComponents` is `elm` / `edge-icell`; both waits use `restricted-resources/$(params.clusterName)/`; and no HCP pipeline under `.tekton/pipelines/hcp-*.yaml` sets `archiveExisting`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Edit the pipeline, run files, README.
- [ ] **Step 4:** Test and `run.sh` pass; `python3 -c 'import yaml…'` parses the three YAML files.
- [ ] **Step 5:** Commit `feat(roks): apply restricted resources in two passes`.

### Task 4: Per-run Secret access for the browser

**Files:**
- Create: `.tekton/tasks/roks-sap-browser-access-task.yaml`
- Modify: `.tekton/tasks/roks-teardown-task.yaml`
- Create: `hack/sap-browser/roks-runner-rbac.yaml`
- Test: `hack/tekton-tests/test_roks_sap_browser_access.sh`; extend `hack/tekton-tests/test_roks_teardown.sh`

**Interfaces:**
- Produces: Task `roks-sap-browser-access`, params `clusterName`, `runnerServiceAccount` (default `roks-sap-browser-runner`), workspace `source`; result `clusterEdgeNodeId` = label `edgelm.sap.com/edge-node-id` of namespace `edgelm` on the ROKS cluster (workspace `kubeconfig`), `""` if the namespace or label is absent (a UUID, not a secret).
- On the pipeline cluster (in-cluster `oc`, never the hub): `oc apply` of Role `roks-sap-browser-<cluster>` (`get` on secrets with `resourceNames` exactly `eic-credentials-roks-<cluster>`, `eic-registry-roks-<cluster>`, `edgelm-kubeconfig-generated-<cluster>`) and RoleBinding `roks-sap-browser-<cluster>` to the runner SA.
- `roks-teardown`: deletes that Role and RoleBinding on the pipeline cluster with `--ignore-not-found`.
- `roks-runner-rbac.yaml` (applied once by the user): SA `roks-sap-browser-runner`; Role `roks-sap-browser-runner` (tekton.dev pipelineruns, taskruns: get; services: create, get, delete; route.openshift.io routes: create, get, delete; serviceaccounts: get, patch with `resourceNames: [roks-sap-browser-runner]`) + RoleBinding; Role `roks-sap-browser-access-manager` (rbac.authorization.k8s.io roles, rolebindings: get, create, patch, delete) bound to SA `pipeline`. Comment: the pipeline SA can only grant `get secrets` it holds itself; if the OAuth proxy logs 403 on subjectaccessreviews, a cluster admin binds `system:auth-delegator` to the runner SA.

- [ ] **Step 1: Write the failing tests** with the harness's fake `oc` (`hack/tekton-tests/fake-bin/oc`): `role_names_only_this_runs_secrets` (applied Role YAML contains exactly the three names and verb `get`, nothing else); `binding_targets_runner_sa`; `edge_node_id_result` (fake `oc get ns edgelm` returns the label → result file holds it); `edge_node_id_empty_when_absent`; teardown: `teardown_deletes_browser_role`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement task, teardown change, RBAC file.
- [ ] **Step 4:** Tests and `run.sh` pass.
- [ ] **Step 5:** Commit `feat(roks): per-run Secret access for the browser task`.

### Task 5: In-cluster client, ROKS inputs, milestone waits

**Files:**
- Modify: `hack/sap-browser/cluster-reader.mjs`
- Create: `hack/sap-browser/roks-inputs.mjs`, `hack/sap-browser/milestones.mjs`
- Test: `hack/sap-browser/cluster-reader.test.mjs`, `roks-inputs.test.mjs`, `milestones.test.mjs`

**Interfaces:**
- `inClusterClient(namespace, { transport } = {}) → { get(kind, name), create(kind, body), patch(kind, name, mergePatch), remove(kind, name) }`; kinds `pipelinerun`, `taskrun`, `secret`, `service`, `serviceaccount`, `route` (`/apis/route.openshift.io/v1`); `patch` sends `application/merge-patch+json`; `remove` treats 404 as success; `create` returns status code 409 as `SetupError` with `code = 'exists'`; no error message contains a response body. `transport(method, path, body, headers) → {status, json}` defaults to the existing https logic. `inClusterReader` keeps its exact behavior.
- `loadRoksInputs(read, pipelineRun, { expectedRunUID, expectedClusterName, postgresPassword }) → { clusterName, pipelineRun, postgres: {host, port, database, username, password}, redis: {host, port, username, password}, registry: {server, namespace, username, password}, attachments: {postgresCA, redisCA} }`. Checks run UID, `spec.pipelineRef.name === 'roks-eic-full-test-pipeline'`, param `clusterName` valid and equal, TaskRuns `validate-and-get-access` and `registry-access` of this run succeeded. Keys read from `eic-credentials-roks-<c>`: `postgres-host`, `postgres-port`, `postgres-database`, `postgres-username`, `postgres-ca.crt`, `redis-host`, `redis-port`, `redis-username`, `redis-password`, `redis-ca.crt` (final review: the producer's real key names); from `eic-registry-roks-<c>`: `server`, `namespace`, `username`, `password`. Missing value → `SetupError` naming the key (for `postgres-*` keys saying deployPostgres must be "true", for `redis-*` keys deployRedis).
- `loadRestrictedKubeconfig(read, clusterName) → string` from `edgelm-kubeconfig-generated-<c>` key `kubeconfig` only.
- `waitForPipelineTask(read, { pipelineRun, pipelineRunUID, pipelineTaskName, signal, intervalMs = 15000, onWait }) → Promise<void>`: finds the TaskRun via `status.childReferences`; resolves on `Succeeded=True`; `SetupError` on `False`, on a PipelineRun that finished without it, or on UID mismatch; rejects with `signal.reason` when aborted.

- [ ] **Step 1: Write the failing tests:** client `route_paths_and_merge_patch`, `remove_tolerates_404`, `errors_hide_bodies`; inputs `maps_roks_keys` (e.g. `postgres.database` from `postgres-database`), `never_reads_admin_kubeconfig` (fixture Secret has `kubeconfig: ADMIN-KUBECONFIG`; `JSON.stringify(result)` does not contain it), `rejects_other_pipeline`, `rejects_unfinished_registry_access`, `requires_postgres_password`, `restricted_kubeconfig_only_from_generated_secret` (reader records names: only `edgelm-kubeconfig-generated-c1`); milestones `resolves_after_success`, `rejects_on_failure`, `rejects_when_run_finished_without_task`, `honors_abort`.
- [ ] **Step 2:** `npm run sap:browser:test` → new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** All `sap:browser` tests pass (existing ones unchanged).
- [ ] **Step 5:** Commit `feat(sap-browser): ROKS inputs, in-cluster client and milestone waits`.

### Task 6: S3 handoff and the elm CLI

**Files:**
- Create: `hack/sap-browser/s3.mjs`, `hack/sap-browser/elm-cli.mjs`
- Modify: `hack/sap-browser/Containerfile` (AWS CLI v2 for linux/amd64 and `unzip`; `script` comes from bsdutils)
- Test: `hack/sap-browser/s3.test.mjs`, `hack/sap-browser/elm-cli.test.mjs`

**Interfaces:**
- `s3Client({ endpoint, bucket, credentials: {accessKeyId, secretAccessKey}, home, run }) → { put(file, key), list(prefix) → [{key, lastModified, size}], get(key, file) }` via `aws s3 cp` / `aws s3api list-objects-v2 --output json`, always `--endpoint-url <endpoint> --no-verify-ssl` (same trust as the bash tasks); child env exactly `{PATH, HOME: home, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_EC2_METADATA_DISABLED: 'true'}`; failures → `SetupError` without stderr. `run(file, args, opts)` defaults to promisified `execFile`.
- `uploadBundle(s3, { file, s3Prefix, component }) → key`: `component ∈ {'elm','edge-icell'}`; basename must match `/^restricted-resources-[A-Za-z0-9_.-]+\.zip$/`; key `${s3Prefix}${component}/${basename}`.
- `fetchElmCli(s3, dir) → Promise<string>`: newest object (by `lastModified`, keys ending `/` ignored) under `tools/elm/`; none → `SetupError('No elm CLI in tools/elm/ of the bucket. Download the Linux x86_64 ELM CLI from the SAP Software Download Center and upload it there.')`; `.zip` → `unzip -o`, `.tar.gz`/`.tgz` → `tar xzf`, `.sar`/`.SAR` → `SetupError('SAR archives are not supported: extract the elm binary with SAPCAR and upload it, or a zip/tar.gz, to tools/elm/.')`, anything else is the binary itself; locate a file named `elm` (depth ≤ 3), `chmod 0o700`, log the object key.
- `runElmInit({ elmPath, contextFile, password, cwd, timeoutMs = 600000, spawnImpl = spawn, platform = process.platform, log = console.log }) → Promise<void>`: runs through a pseudo-terminal — linux `script -q -e -c '<elm> init -c <cfg>' /dev/null` (shell-quote both paths), darwin `script -q /dev/null <elm> init -c <cfg>`; child env exactly `{PATH, HOME: cwd, TERM: 'dumb'}`; writes `password + '\n'` once, when the accumulated output first contains `password` (case-insensitive); relays output line by line with every occurrence of the password replaced by `***`; exit 0 resolves; non-zero → `SetupError('elm init failed (exit <n>)')`; timeout kills the child → `SetupError('elm init timed out')`.

- [ ] **Step 1: Write the failing tests:** s3 `put_command_line`, `child_env_is_minimal` (set `process.env.SAP_TEST_SECRET`; captured env lacks it and has exactly the listed keys), `list_parses_json`, `errors_hide_stderr`; `upload_bundle_key`, `upload_bundle_rejects_other_names` (`context.cfg`, `../x.zip`, `restricted-resources-x.tar`); elm `fetch_picks_newest`, `fetch_extracts_tar_gz` (real archive built with `tar` in a temp dir), `fetch_rejects_sar`, `fetch_reports_missing_cli`; init with a fake `elm` bash script (`read -rs -p 'Context Password: ' pw`; prints `initialized` when `pw` equals the value written into the script, exits 3 otherwise; also prints `env`): `init_answers_prompt`, `init_wrong_password_fails`, `init_masks_password` (captured log never contains the password), `init_env_has_no_aws_keys`, `init_times_out` (fake sleeps; `timeoutMs: 500`).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement modules and Containerfile change.
- [ ] **Step 4:** Tests pass (macOS and Linux `script` syntax both covered by `platform`).
- [ ] **Step 5:** Commit `feat(sap-browser): S3 handoff, elm CLI fetch and elm init`.

### Task 7: Per-run Route behind the OAuth proxy

**Files:**
- Create: `hack/sap-browser/route.mjs`
- Test: `hack/sap-browser/route.test.mjs`

**Interfaces:**
- Consumes: Task 5 `inClusterClient`.
- `routeName(clusterName) → 'sapb-' + clusterName` (final review: shortened from `roks-sap-browser-` so the router host label and the SA annotation name stay within 63 characters).
- `openRoute(client, { name, podName, podUID, taskRunName, serviceAccount, port = 4180, timeoutMs = 120000, intervalMs = 2000 }) → Promise<{ url, close }>`:
  - Service `name`: selector `{'tekton.dev/taskRun': taskRunName}`, port/targetPort `port`, `ownerReferences: [{apiVersion: 'v1', kind: 'Pod', name: podName, uid: podUID}]`.
  - Route `name` → that Service, `tls: {termination: 'edge', insecureEdgeTerminationPolicy: 'Redirect'}`, same ownerReferences.
  - Merge-patch the SA: annotation `serviceaccounts.openshift.io/oauth-redirectreference.<name>` = `JSON.stringify({kind: 'OAuthRedirectReference', apiVersion: 'v1', reference: {kind: 'Route', name}})`.
  - A create answering `exists` (left by a killed pod of an earlier run) → remove, then create again.
  - Poll until `status.ingress[0]` has the condition `Admitted` `True` and a host (final review: a host alone is not enough); `url = 'https://<host>/vnc.html?autoconnect=1&resize=remote&path=websockify'`; `Admitted` `False` → `SetupError('Route not admitted: <reason>')`; timeout → `SetupError`; both clean up.
  - `close()`: removes Route and Service, patches the annotation to `null`; never throws (logs a one-line warning).

- [ ] **Step 1: Write the failing tests** with a fake client recording calls: `creates_service_route_and_annotation` (bodies deep-equal the above), `url_from_admitted_host`, `recreates_stale_objects`, `close_removes_everything`, `close_never_throws`, `times_out_without_host`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit `feat(sap-browser): per-run Route for the ROKS browser`.

### Task 8: Deploy and teardown flow with page steps behind an interface

**Files:**
- Create: `hack/sap-browser/elm-pages.mjs`, `hack/sap-browser/roks-flow.mjs`
- Test: `hack/sap-browser/roks-flow.test.mjs`

**Interfaces:**
- Consumes: Task 5 (`waitForPipelineTask`, `loadRestrictedKubeconfig`), Task 6 (`uploadBundle`, `fetchElmCli`, `runElmInit`).
- `elm-pages.mjs` exports `elmPages` with these methods (Plan B implements them; here each throws `SetupError('ELM screen step not mapped yet: <method>. Record it with sapBrowserMode inspect.')`):
  `edgeNodeState(page, clusterName) → 'absent'|'added'|'initialized'|'eic-deployed'|'unknown'`,
  `edgeNodeId(page, clusterName) → string`,
  `addEdgeNode(page, {clusterName, registry})`,
  `downloadElmZip(page, {clusterName, dir}) → path`,
  `setUpCloudConnector(page, {clusterName, kubeconfigFile, password, dir}) → contextFile`,
  `deployEic(page, {clusterName, inputs, files})`,
  `downloadEicZip(page, {clusterName, dir}) → path`,
  `finishEicDeployment(page, {clusterName})`,
  `deleteEdgeNode(page, {clusterName})`.
- `contextPassword() → string` (24 random bytes, base64url).
- `runDeployFlow(ctx) → Promise<'deployed'>` with `ctx = { page, steps, inputs, clusterEdgeNodeId, s3, s3Prefix, dir, waitForTask(pipelineTaskName), loadKubeconfig(), fetchElm(dir), elmInit(opts), password, log }`. Order (SAP-changing steps are skipped on resume; downloads never are, because Task 1 archived the folders at run start):
  1. `state = edgeNodeState`; `'unknown'` → `SetupError`, nothing else called.
  2. `state !== 'absent'` and `edgeNodeId !== clusterEdgeNodeId` → log "leftover Edge Node", `deleteEdgeNode`, `state = 'absent'`.
  3. `state === 'absent'` → `addEdgeNode({clusterName, registry: inputs.registry})`.
  4. `downloadElmZip` → `uploadBundle(…, 'elm')`.
  5. `waitForTask('generate-sa-based-kubeconfig')`.
  6. `state ∈ {absent, added}` → write `loadKubeconfig()` to `<dir>/edgelm-kubeconfig.yaml` (0600), `setUpCloudConnector`, `fetchElm(dir)`, `elmInit({elmPath, contextFile, password, cwd: dir})`.
  7. `state !== 'eic-deployed'` → write `postgres-ca.crt`, `redis-ca.crt` (0600), `deployEic`.
  8. `downloadEicZip` → `uploadBundle(…, 'edge-icell')`.
  9. `waitForTask('configure-mesh-eic')`.
  10. `finishEicDeployment`; return `'deployed'`.
- `runTeardownFlow({ page, steps, clusterName, log }) → Promise<'edge-node-deleted'|'nothing-to-delete'>` (`'unknown'` → `SetupError`).

- [ ] **Step 1: Write the failing tests** with fake steps/s3/waits recording one ordered call log: `fresh_run_order` (exact sequence of steps 1–10), `resume_initialized_skips_sap_changes` (matching id, `'initialized'`: no `addEdgeNode`, `setUpCloudConnector` or `elmInit`; `deployEic` and both uploads still happen), `resume_eic_deployed_skips_deploy`, `leftover_node_is_recreated` (different id → `deleteEdgeNode` before `addEdgeNode`), `unknown_state_changes_nothing`, `kubeconfig_file_private` (mode 0600, content equals the restricted kubeconfig), `teardown_absent`, `teardown_deletes`, `stubs_say_not_mapped` (calling any `elmPages` method rejects with the message above).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit `feat(sap-browser): ROKS deploy and teardown flow`.

### Task 9: ROKS entry point and entrypoint switch

**Files:**
- Create: `hack/sap-browser/roks-pipeline.mjs`
- Modify: `hack/sap-browser/entrypoint.sh`
- Test: `hack/sap-browser/roks-pipeline.test.mjs`

**Interfaces:**
- Consumes: Tasks 5–8; `writeStatus`, `waitForFinish` from `session.mjs` (unchanged); `control.mjs` `status`/`finish` work as today.
- `roksPipelineOptions(env) → options`. Env: `SAP_BROWSER_MODE` (`inspect`|`auto`), `SAP_BROWSER_PHASE` (`deploy`|`teardown`), `SAP_ELM_URL` (https, no credentials), `PIPELINE_NAMESPACE`, `PIPELINE_RUN`, `PIPELINE_RUN_UID`, `CLUSTER_NAME`, `POD_NAME`, `POD_UID`, `TASKRUN_NAME`, `RUNNER_SERVICE_ACCOUNT`, `S3_PREFIX` (must equal `restricted-resources/<CLUSTER_NAME>/`), `BUCKET_HOST`, `BUCKET_PORT`, `BUCKET_NAME`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `POSTGRES_ADMIN_PASSWORD` (required for deploy + auto), `CLUSTER_EDGE_NODE_ID` (may be empty), `HUB_KUBECONFIG_SECRET_NAME`, `SAP_BROWSER_SESSION_MINUTES` (default 180, 1–240), `SAP_BROWSER_LOGIN_MINUTES` (default 30, ≤ session), `SAP_BROWSER_SESSION_DIR`, `SAP_BROWSER_RESULT_PATH`; `PWDEBUG`/`DEBUG=pw:*` rejected.
- `main(env, deps) → Promise<outcome>`; never rejects; writes the outcome to `SAP_BROWSER_RESULT_PATH`. Outcomes: `skipped-hub` (hub set — no browser, no Route), `inspection-finished`, `deployed`, `edge-node-deleted`, `nothing-to-delete`, `handed-over` (flow failed; browser kept open until `control.mjs finish`, the user closing Chromium, or the session deadline), `failed` (bad options, Route/login/session failure). Sequence: open Route → print `Open <url>, log in to OpenShift, then log in to SAP in the browser shown.` → launch Chromium (headed, as `pipeline.mjs`) → goto ELM → wait for login (same checks as `pipeline.mjs`; extracting a shared helper is fine if `pipeline.mjs` behaves the same) → `inspect`: `page.pause()`; `auto`: deploy or teardown flow → finally close Route, browser, private files. `deps` (all injectable for tests): `openRoute`, `launchBrowser`, `client`, `s3Factory`, `flows`, `steps`.
- `entrypoint.sh`: `SAP_BROWSER_ACCESS` (`port-forward` default | `route`): print the port-forward/exec instructions only for `port-forward`; `SAP_BROWSER_ENTRY` (default `pipeline.mjs`) selects the Node file run from the session code dir. HCP defaults unchanged.

- [ ] **Step 1: Write the failing tests:** `rejects_prefix_mismatch`, `rejects_long_session` (241), `hub_skips_without_browser` (fake `launchBrowser` never called, outcome `skipped-hub`), `inspect_outcome`, `auto_deploy_outcome`, `flow_failure_hands_over` (flow throws `SetupError`, finish file written → `handed-over`), `unexpected_error_is_failed_not_thrown`, `route_closed_on_every_path`, `result_file_written`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `roks-pipeline.mjs` and the `entrypoint.sh` switch (shellcheck clean).
- [ ] **Step 4:** Tests pass; `shellcheck -x hack/sap-browser/entrypoint.sh` clean.
- [ ] **Step 5:** Commit `feat(sap-browser): ROKS browser entry point behind a Route`.

### Task 10: ROKS browser Task, pipeline wiring and docs

**Files:**
- Create: `.tekton/tasks/roks-sap-browser-task.yaml`
- Modify: `.tekton/pipelines/roks-eic-full-test-pipeline.yaml`, `.tekton/roks-eic-ossm3-run.yaml`, `.tekton-examples/roks-eic-ossm3-run.yaml`, `.tekton/README.md`, `hack/sap-browser/PIPELINE.md`
- Test: `hack/tekton-tests/test_roks_sap_browser_wiring.sh`

**Interfaces:**
- Consumes: Task 3 names, Task 4 task/result, Task 9 env contract.
- Task `roks-sap-browser`: params `mode`, `phase`, `runnerImage`, `oauthProxyImage` (default `image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4`), `elmUrl`, `pipelineRun`, `pipelineRunUID`, `clusterName`, `obcName`, `roksCredentialsSecretName`, `hubKubeconfigSecretName`, `clusterEdgeNodeId` (default `""`), `runnerServiceAccount` (default `roks-sap-browser-runner`), `sessionMinutes` (`"180"`), `loginMinutes` (`"30"`); result `outcome`; optional read-only workspace `source` (code from the checkout, as `hcp-sap-browser`); memory volumes as `hcp-sap-browser`.
  - Sidecar `oauth-proxy`: bash generates a cookie secret from `/dev/urandom` into a memory volume, then execs `oauth-proxy --provider=openshift --http-address=:4180 --https-address= --upstream=http://127.0.0.1:6080 --openshift-service-account=$(params.runnerServiceAccount) --cookie-secret-file=<file> --cookie-secure=true --skip-provider-button --pass-access-token=false --email-domain=* --openshift-sar={"namespace":"$(context.taskRun.namespace)","resource":"pods","subresource":"portforward","verb":"create"}`.
  - Step `browser` (`script`): runs `${SAP_BROWSER_ENTRYPOINT:-/opt/sap-browser/entrypoint.sh}` under `dumb-init` with `SAP_BROWSER_ACCESS=route`, `SAP_BROWSER_ENTRY=roks-pipeline.mjs` and the Task 9 env (`POD_NAME`/`POD_UID` via fieldRef, `TASKRUN_NAME=$(context.taskRun.name)`, OBC keys via `secretKeyRef`/`configMapKeyRef`, `POSTGRES_ADMIN_PASSWORD` via `secretKeyRef` with `optional: true`); `|| true`; writes `failed` to the result if it is empty; `exit 0`. Same securityContext and resources as `hcp-sap-browser`.
- Pipeline: params `sapBrowserMode` (default `"disabled"`; `disabled|inspect|auto`), `sapBrowserImage` (`""`), `sapElmUrl` (`""`), `sapBrowserSessionMinutes` (`"180"`), `sapBrowserLoginMinutes` (`"30"`), `oauthProxyImage`. Tasks, each with `when: sapBrowserMode notin ["disabled"]`: `sap-browser-access` runAfter `[validate-and-get-access]`; `sap-browser-deploy` (`phase: deploy`, `clusterEdgeNodeId: $(tasks.sap-browser-access.results.clusterEdgeNodeId)`) runAfter `[sap-browser-access, registry-access]`; `sap-browser-teardown` (`phase: teardown`) runAfter `[approval-teardown]`. `approval-elm-eic-iflow-deployed` runAfter adds `sap-browser-deploy`; `teardown-roks` runAfter `[approval-teardown, sap-browser-teardown]`.
- Run files (identical): `sapBrowserMode: "disabled"` with a comment on enabling; commented `sapBrowserImage`, `sapElmUrl`; commented `taskRunSpecs` giving `sap-browser-deploy` and `sap-browser-teardown` the SA `roks-sap-browser-runner`.
- README ROKS section, new "Browser automation (optional)": one-time setup (build/push the image per `PIPELINE.md`, `oc apply -f hack/sap-browser/roks-runner-rbac.yaml`, upload the Linux `elm` CLI to `tools/elm/`), enabling it, what the user does (open the Route link from the `sap-browser-deploy` log, OpenShift login, SAP login; again at teardown), the outcomes, the manual fallback, and that `auto` hands over at once until Plan B maps the screens — use `inspect` to record them. `PIPELINE.md`: short ROKS pointer to that section.

- [ ] **Step 1: Write the failing test:** wiring (the `when`, runAfter sets and result wiring above; `sap-browser-access` before any apply); sidecar args contain exactly the `--openshift-sar` JSON above; step script: extracted with `SAP_BROWSER_ENTRYPOINT=false` → rc 0 and result `failed`; with a fake entrypoint that writes `deployed` → rc 0 and result `deployed`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement task, wiring, run files, docs.
- [ ] **Step 4:** Test, `run.sh`, `npm run sap:browser:test`, `npm run cspell` pass.
- [ ] **Step 5:** Commit `feat(roks): optional Playwright browser task in the ROKS pipeline`.

---

## After this plan (not for implementers)

1. The user builds and pushes the runner image, applies `roks-runner-rbac.yaml`, uploads the `elm` CLI to `tools/elm/`.
2. A ROKS run with `sapBrowserMode: inspect` and the taskRunSpecs: the user opens the Route link, logs in, and records Add Edge Node (incl. image replication with the ICR values), Prerequisites (ELM zip), Set Up Embedded Cloud Connector, the Edge Node state indicators and id, Configuration / EIC deploy form, EIC zip, anything after the second apply, and Edge Node deletion. Recordings stay under `.sap-browser/` (git-ignored).
3. Plan B: implement `elm-pages.mjs` from those recordings, with fixture-page tests like `registration.test.mjs`.
