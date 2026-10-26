<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-FileContributor: Manjun Jiao (@mjiao)

SPDX-License-Identifier: Apache-2.0
cspell:words Containerfile ELMB PWDEBUG SAPCAR bsdutils portforward promisified redirectreference serviceaccounts subjectaccessreviews subresource urandom
-->

# Design: Playwright automation of the ELM steps in the ROKS EIC pipeline

Date: 2026-10-26
Status: draft, waiting for the user's review

## Intent

Today a ROKS EIC validation run (`roks-eic-full-test-pipeline`) needs the
user in the SAP Edge Lifecycle Management (ELM) web UI for a long, manual
stretch: register the cluster as an Edge Node, download restricted-resources
zips and upload them to S3, set up the embedded Cloud Connector with a
command-line tool, deploy Edge Integration Cell (EIC) with a form full of
values that the pipeline itself produced, and later remove the Edge Node
again. The user wants to log in to SAP once and have Playwright do the rest:
fill in every field, click every button, download the files, run the
commands, and hand the zips to the pipeline.

## The flow (confirmed by the user, 2026-10-26)

Step 1 — register the Edge Node:

1. The pipeline creates the ROKS cluster.
2. The user logs in to SAP BTP / ELM in a browser (SSO, possibly MFA).
3. Playwright adds the Edge Node (restricted access) and downloads the ELM
   restricted-resources zip.
4. The zip goes to `restricted-resources/<clusterName>/elm/` in the OBC bucket.
5. The pipeline applies the ELM zip, sets up the mesh and generates the
   restricted kubeconfig (`edgelm-kubeconfig-generated-<clusterName>`).
6. Initialize Edge Node → Set Up Embedded Cloud Connector (screen shown by the
   user): upload that kubeconfig, enter a context password, click
   **Download Bootstrapping File** (`context.cfg`); get the ELM CLI
   (`ELMB00_<Version>-<Extension>`, OS tabs MacOS / Windows / Linux), extract
   the `elm` binary, `chmod a+x elm`, run `./elm init -c context.cfg` and
   answer its prompt for the context password. The CLI's Download link leads
   to the SAP Software Download Center, which needs a second login with an
   S-user (stated by the user).

Step 2 — deploy EIC:

7. Playwright deploys the Edge Integration Cell solution and fills in its
   parameters.
8. Playwright downloads the EIC restricted-resources zip; it goes to
   `restricted-resources/<clusterName>/edge-icell/`.
9. The pipeline applies the EIC zip (a second apply, after registration).
10. EIC comes up; the user deploys the iFlows and approves
    `approval-elm-eic-iflow-deployed`; the endpoint tests run.

Teardown:

11. After `approval-teardown`, Playwright removes the Edge Node from ELM
    (the user logs in again), then the pipeline destroys the cluster.

Today's pipeline applies both zips in one go at the start; the user did that
only to simplify. The real order above needs two applies.

## Goals

- Playwright performs steps 3, 4, 6, 7, 8 and 11, including every click that
  changes SAP state ("Add Edge Node", the EIC deploy, the Edge Node removal).
- The user's only manual actions in a normal run: one SAP login for steps
  3–8, one for step 11, deploying the iFlows, and the existing approvals.
- The browser runs inside the pipeline (a task pod) and the user reaches it
  through an OpenShift **Route**, not `oc port-forward`.
- The pipeline applies the restricted resources in two batches: the ELM zip
  before registration, the EIC zip after step 8.
- Build on the existing helper `hack/sap-browser/` (Playwright, Chromium on a
  virtual display, noVNC, inputs read from the run's Secrets; see its
  `README.md` and `PIPELINE.md`) rather than starting over.

## Non-goals

- The HCP, ROSA and ARO pipelines (later; the user agreed to ROKS first). The
  existing optional `hcp-sap-browser` task in `hcp-ossm3-validation-pipeline`
  keeps working unchanged.
- Deploying the test iFlows and approving `approval-elm-eic-iflow-deployed`
  (stays manual for now — my guess, not stated by the user).
- Hub-cluster mode of the ROKS pipeline (`hubKubeconfigSecretName` set): the
  browser reads the run's Secrets in the pipeline namespace only, and stops
  with a clear message when a hub is configured.
- Automating the SAP login itself, or storing an SAP session between runs.

## Anti-goals

- A logged-in SAP browser reachable by anyone who can reach the cluster's
  apps domain. The Route must sit behind OpenShift authentication.
- Credentials (database passwords, registry API key, context password,
  kubeconfig, `context.cfg`) in logs, task results, approval descriptions,
  Playwright traces or screenshots, or anywhere outside memory-backed pod
  storage that is removed when the session ends.
- A broken browser flow (SAP UI change, SSO failure from the pod, timeout)
  that blocks the manual path: the user must always be able to finish by
  hand in the same browser or in their own browser, upload the zips to the
  same S3 folders, and let the run continue.
- Any kubeconfig other than the restricted `edgelm-kubeconfig-generated-<cluster>`
  uploaded to SAP. The `kubeconfig` key of `eic-credentials-roks-<cluster>` is
  a cluster-admin token kubeconfig; the flow reads only the database and Redis
  keys from that Secret. (Today's `hack/sap-browser/inputs.mjs` prefers the
  combined Secret's `kubeconfig` — that must not carry over to ROKS.)
- A billable ROKS cluster left behind because the Edge Node removal failed:
  `teardown-roks` must run anyway.
- Repeating SAP actions blindly on a rerun (a second Edge Node, a second EIC
  deployment).

## Constraints

- In Tekton, a failed task stops the PipelineRun from scheduling any new
  task. The browser tasks therefore report failure in a result and the log
  but exit successfully, so the manual path and the teardown continue.
- ApprovalTasks cannot be skipped conditionally on this cluster (they ignore
  `when`; any gate pauses every run). Regular tasks skipped by `when` do not
  block the tasks that run after them.
- The pipeline cluster and the browser run inside the SAP internal network,
  with no access from outside it (stated by the user). The Route's login
  still matters inside that network: without it anyone on the SAP network
  who has the link could drive the logged-in SAP session.
- The browser pod reaches the cluster API and the SAP tenant/identity
  provider; whether SAP SSO works from the pod is untested
  (`hack/sap-browser/PIPELINE.md`) and is the first thing to try.
- The ROKS credentials Secret `eic-credentials-roks-<cluster>` uses other key
  names than the HCP Secret the helper reads today (`postgres-host`,
  `postgres-port`, `postgres-database`, `postgres-username`, `postgres-ca`,
  `redis-host`, `redis-port`, `redis-username`, `redis-password`,
  `redis-ca`, `kubeconfig` versus the HCP `postgres-dbname`, `postgres-user`,
  `postgres-tls-root-cert`, `redis-tls-cert`, …). The PostgreSQL admin
  password is not in it: it is key `POSTGRES_ADMIN_PASSWORD` of
  `roks-ci-credentials`, which also holds the IBM Cloud API key and the state
  bucket's HMAC keys — so the browser pod gets that one key through a step
  `env` `secretKeyRef`, never `get` on the whole Secret.
- ICR access for ELM image replication is in `eic-registry-roks-<cluster>`
  (`server`, `namespace`, `username`, `password`); on ROKS the wizard's
  "Replicate Container Images" is used with these values, unlike the HCP
  helper, which unchecks it (my reading of the ROKS design; confirm in the
  walkthrough).
- `ossm3-prepare-namespaces` creates all EIC namespaces (`edge-icell`,
  `edge-icell-secrets`, …) if missing and labels them; in the two-batch
  order it would run before the EIC zip, whose `apply-restricted-resources.sh`
  validates namespace ownership through `edgelm.sap.com/edge-node-id` labels
  (CONFLICT / legacy-claim / PROMPT). The second apply must not hit an
  ownership conflict.
- Existing repo rules: Tekton v1, UBI9 bash with `set -euo pipefail` in
  embedded scripts, shellcheck-clean at default severity, SPDX headers,
  `npm run cspell` clean, `npm run sap:browser:test` and the
  `hack/tekton-tests/` harness pass and cover the new tasks, DCO sign-off,
  PRs to `redhat-sap/sap-edge`.

## Decided by the user

- Playwright clicks every button itself, including "Add Edge Node" and the
  EIC deploy (no stop at Configuration Review as in today's helper).
- The browser is reached through a Route (no `oc port-forward`).
- ROKS first; the other pipelines later.
- At teardown Playwright deletes the Edge Node in ELM, and the pipeline
  destroys the cluster.
- **S3 handoff stays:** the browser task puts the downloaded zips into the
  run's S3 folders and the pipeline applies them with the shared task; the
  browser pod does not run `apply-restricted-resources.sh` itself. Reasons:
  the pipeline must wait mid-run either way (mesh and restricted kubeconfig
  sit between the ELM zip and the Cloud Connector step), and the manual and
  automated paths stay identical from the folder on, with one tested apply.
- The flow above, including the Embedded Cloud Connector steps run by the
  automation (`context.cfg` download, `chmod`, `elm init`).

## My calls (to check while reading)

- **Where the browser runs:** only in a pipeline task pod (Linux `elm`
  binary, cluster API reachable, credentials never on a laptop). No local
  variant of the flow is built; when it breaks (or SSO fails from the pod),
  the fallback is the manual path.
- **Route protection:** the noVNC page sits behind the OpenShift OAuth proxy
  (HTTPS only), letting through only users with access to the pipeline
  namespace. The Route and its Service exist only while a browser task runs
  and are removed at the end of the session (and garbage-collected with the
  pod if the task is killed). Each concurrent run gets its own Route.
- **When the deploy session starts:** after `validate-and-get-access` and
  `registry-access` (the cluster exists), not at run start — cluster creation
  takes 60–90 minutes and the SAP login would expire. The task prints the
  Route link in its log.
- **One session for steps 3–8:** the browser task waits inside the same SAP
  session for the pipeline's milestones (the generated kubeconfig Secret of
  this run, then the second apply's TaskRun success), checked against the
  PipelineRun as the helper already does (run UID, TaskRun ownership,
  Secret creation time).
- **Upload gate becomes a wait:** `approval-upload-restricted-resources` is
  replaced by tasks that wait until a zip is present in `elm/` (before the
  first apply) and in `edge-icell/` (before the second). They do not care who
  uploaded it, so the manual path keeps working and a run that Playwright
  completes does not pause for an approval. This reverses the earlier "always
  pause" choice for ROKS, because Playwright now does the upload.
- **Only this run's zips count:** every zip carries the Edge Node's id, and
  teardown deletes that node, so zips left in the folders by an earlier run
  are wrong for the next one. Before waiting, zips older than this
  PipelineRun's start move to `restricted-resources/<clusterName>/archive/`
  (non-destructive; `apply-rbac` downloads only `elm/` and `edge-icell/`),
  and a wait passes only on a zip uploaded during this run. This replaces
  "a retest reuses the uploaded zips" from commit f3a20a1: with the manual
  path every run needs a fresh upload; Playwright re-downloads anyway.
- **Two applies:** `ossm3-download-and-apply-rbac` runs twice, with
  `requiredComponents` `elm` and then `edge-icell` (no change to the shared
  task).
- **Browser on/off:** a pipeline param selects the mode; with it off, the
  browser tasks are skipped and the run works fully by hand (upload to the
  folders, register and deploy in your own browser).
- **Reruns:** an Edge Node named after the cluster that already exists in
  ELM is trusted only if the cluster carries that node's
  `edgelm.sap.com/edge-node-id` (the ELM zip was applied there); then the
  flow resumes and skips what is done (initialized, EIC deployed). Otherwise
  the node is a leftover of an earlier cluster (a failed run has no teardown,
  a teardown login may time out): Playwright deletes it and starts over. A
  state the flow does not recognize stops it, leaves the browser open for the
  user, and the manual path takes over.
- **Secret access of the browser pod:** a per-run Role, created by the
  pipeline before the browser task and deleted after it, grants `get` only on
  that run's `eic-credentials-roks-<cluster>`, `eic-registry-roks-<cluster>`
  and `edgelm-kubeconfig-generated-<cluster>` (`resourceNames`), plus the
  PipelineRun/TaskRun reads the helper already does — not namespace-wide
  `get secrets` as in `hack/sap-browser/runner-rbac.yaml`, which here would
  expose `roks-ci-credentials` (IBM Cloud API key, HMAC keys). The pipeline's
  service account needs the right to create that Role and RoleBinding.
- **Teardown:** a teardown browser task after `approval-teardown` (second
  login) removes the EIC deployment if ELM requires it and deletes the Edge Node;
  `teardown-roks` runs after it whatever its outcome, with a time limit for
  the login.
- **Where the `elm` CLI comes from:** not from the Software Download Center
  on every run (a second S-user login per run, on another SAP site), and not
  baked into the runner image (SAP software in a pushed image raises
  redistribution questions). The user downloads the Linux x86_64 build once
  per CLI version and uploads it to `tools/elm/` in the same OBC bucket —
  outside `restricted-resources/`, so no bundle download ever picks it up; the
  browser task takes the newest file there and logs its version.
- **Context password:** generated per run, kept in memory, given to the UI
  and to `elm init` only.

## Left to the builder

- **Live walkthrough first.** The screens not yet mapped — the Prerequisites
  tab (ELM zip download), the Embedded Cloud Connector screen beyond the
  user's screenshot, the Configuration tab, the EIC deploy form and its
  fields, where the EIC zip appears, any "continue after applying" button,
  and the Edge Node removal — must be captured in an authenticated session by
  the user (the helper's `inspect` recording mode, or screenshots). Labels
  and selectors come from that, not from guesses.
- Which EIC parameters map to which Secret keys (PostgreSQL, Redis, ICR,
  host `eic.<ingress>`, CA certificates).
- The CLI archive format from the Software Download Center (a `.SAR` needs
  SAPCAR in the image) and whether ELM requires a matching CLI version (then
  fail with a clear "upload a newer CLI to tools/elm/" message).
- Whether `elm init` accepts the context password without a terminal prompt;
  otherwise answer the prompt through a pseudo-terminal. What `elm init`
  needs to reach and how long it runs.
- How the downloaded zips get to S3 from the pod (OBC credentials via step
  `env`; aws CLI in the image or a Node S3 client).
- How to avoid the ownership conflict in the second apply (for example: label
  only the ELM namespaces before registration and overlay the EIC namespaces
  after the second apply, or prove that the script's legacy-claim with `--yes`
  accepts the pre-created namespaces).
- OAuth proxy mechanics for per-run Routes (service-account OAuth client
  redirect references, the access check), and the RBAC for the browser task
  to create and delete its Route and Service.
- The runner image: built from `hack/sap-browser/Containerfile`, plus
  whatever `elm` and the S3 upload need; where it is pushed (a param, as in
  the HCP task) and the one-time build documented.
- Whether to generalize `hcp-sap-browser` into one task used by both
  pipelines or add a ROKS task beside it, without changing HCP behavior.
- Timeouts for login and the overall session, and how the user learns the
  Route link (task log, and where else it is cheap to show).
