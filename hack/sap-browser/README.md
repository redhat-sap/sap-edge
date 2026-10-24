<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-License-Identifier: Apache-2.0
-->

# SAP browser setup helper

Visible-browser automation for the manual SAP step in
`hcp-ossm3-validation-pipeline`. You complete SAP SSO/MFA in the browser; Playwright
continues in that same session. The existing Tekton approval gate remains in place.

For the optional **OpenShift pipeline runner**, including browser access from a
Citrix desktop and standalone rehearsal runs, see [PIPELINE.md](PIPELINE.md).
It uses noVNC over `oc port-forward`; no permanent server is required.

## Current scope

- `inspect`: opens ELM, waits for login and the Edge Nodes page, then opens the
  Playwright Inspector to record the remaining setup steps.
- `prepare-inputs`: collects a run's inputs inside the SAP network into a private
  local file, without launching a browser or transferring the file anywhere.
- `review-registration`: reads the selected PipelineRun's configuration and Secrets,
  fills the restricted-access edge-node wizard, and stops at Configuration Review.
  This uses labels inspected in the live ELM UI on 2026-10-22.
  Alternatively, `--cluster NAME` prepares only the form without Kubernetes access.
- `run`: runs a reviewed local flow with cluster-specific inputs and requires its
  readiness verification to pass. **No complete tenant-specific deployment flow is
  included yet.** Initialization, EIC configuration/deployment and iFlow deployment
  still need to be mapped in an authenticated walkthrough.

The registration review uses main namespace `edgelm`, restricted access enabled,
optional HA (`--ha`), and no external Cloud Connector, image replication or HTTP
proxy. Use `inspect` if your environment needs other settings. It does not click
Add Edge Node or upload the kubeconfig. An existing node with the exact name stops
the review flow so you can inspect or resume its deployment manually.

## Install

Requires Node.js 20+ and an interactive desktop for browser modes. Direct pipeline
access and `prepare-inputs` additionally require `oc` or `kubectl` with read access
to PipelineRuns, TaskRuns and the two named Secrets in the pipeline namespace.
Browser modes using `--inputs` do not require Kubernetes connectivity or a CLI.

From the repository root:

```bash
npm ci
npm run sap:browser:install
```

Alternatively use an installed Google Chrome with `--channel chrome`. It starts
with an isolated temporary profile; it does not reuse your normal Chrome login.
Corporate browser policies may affect automated Chrome instances.

## SAP VPN and Citrix

The laptop running Citrix Viewer does not automatically have the remote desktop's
network access. Run cluster commands in an environment that can reach the cluster.
If the browser runs on the Citrix desktop, run Playwright there too; this helper
does not automate the Citrix video display or connect to the remote browser through
Citrix Viewer. Availability of Node.js, a browser and a terminal inside Citrix must
be established before choosing that deployment location.

When those tools are available, collect inputs inside the SAP environment:

```bash
node hack/sap-browser/cli.mjs prepare-inputs \
  --context YOUR_PIPELINE_CLUSTER_CONTEXT \
  --namespace YOUR_PIPELINE_NAMESPACE --pipeline-run YOUR_PIPELINE_RUN \
  --output .sap-browser/run-inputs
```

The collector uses only Node.js built-ins and the Kubernetes CLI; it does not need
Playwright installed. It creates a new output directory and refuses to overwrite
an existing one. `inputs.json` contains the restricted kubeconfig, database/cache
credentials and certificates. The default filesystem permissions are 0700 for
the directory and 0600 for the file on POSIX systems. On Windows, use a private
location with access restricted to your account through Windows permissions.

On the SAP desktop with a browser and Playwright installed, consume that file:

```bash
npm run sap:browser -- review-registration \
  --url "$SAP_ELM_URL" --inputs .sap-browser/run-inputs/inputs.json --channel chrome
```

`run --flow ...` accepts the same `--inputs` option. Neither browser mode contacts
Kubernetes when that option is used; the collection time is printed and the flow
must still verify SAP deployment readiness. Keep the file in the SAP environment
unless an approved transfer to another runner is part of your workflow. The helper
performs no transfer, tunnel or automatic deletion of the source input file.
Delete it from that environment when it is no longer needed. Temporary upload
files created by the browser helper are still removed at session end.

If Citrix provides only a browser and no usable runtime/terminal, continue with
the name-only registration preview locally. Completing deployment will require
a runner with the necessary tools inside the SAP network, or a separate desktop
automation workflow for the Citrix interface.

## First walkthrough

Use the direct **Edge Lifecycle Management** URL from the browser, rather than
the BTP cockpit URL. Keep it in a local environment variable:

```bash
export SAP_ELM_URL='https://YOUR-TENANT/comsapclmedgelm.comsapclmedgelm/index.html'
npm run sap:browser -- inspect --url "$SAP_ELM_URL" --channel chrome
```

1. Complete SAP login/MFA in the new browser. Open Edge Nodes in the same tab.
2. Once Edge Nodes is visible, Inspector opens. Use its **Record** control to
   capture the setup steps. Recording starts after login, so your login password
   and MFA entry are not recorded by this helper.
3. Keep the raw recording under `.sap-browser/`, which is ignored by Git and the
   spell checker. Recordings can contain the form values you enter, including
   credentials; replace these with `inputs` and `files` references before review
   or committing a flow.
4. Resume Inspector and press Enter in the terminal when finished.

The helper does not save authentication state, traces, screenshots or recordings
automatically. It checks the configured tenant origin and the Edge Nodes heading
before continuing. If login opens another tab, return to/reload ELM in the original
tab after signing in. Expired authentication requires another interactive login.

## Fill registration for a pipeline run

To rehearse the registration form before connecting a cluster, use a name-only
preview. This does not read Secrets, check cluster readiness, or create an edge node:

```bash
npm run sap:browser -- review-registration \
  --url "$SAP_ELM_URL" --cluster test-cluster --channel chrome
```

For configuration and credentials from a real pipeline run, use the following
command instead. Do not combine `--cluster` with the pipeline options.

Wait for `get-all-accesses` to succeed and the pipeline to reach
`approval-elm-eic-iflow-deployed`, then run:

```bash
npm run sap:browser -- review-registration \
  --url "$SAP_ELM_URL" \
  --context YOUR_PIPELINE_CLUSTER_CONTEXT \
  --namespace YOUR_PIPELINE_NAMESPACE \
  --pipeline-run YOUR_PIPELINE_RUN \
  --channel chrome
```

The context is for the cluster **running Tekton**, not the HCP guest or remote hub.
The helper derives `hostedClusterName` and `datastoreType` from that PipelineRun.
It verifies ownership and success of the run's `get-all-accesses` TaskRun and checks
that the credential Secret was created during that task. Reusing a cluster name
across concurrent runs is not supported because the pipeline shares Secret names.

Inputs come from:

- `eic-credentials-hcp-<cluster>`: PostgreSQL and Redis/Valkey settings, certificates
  and restricted kubeconfig.
- `edgelm-kubeconfig-generated-<cluster>`: restricted kubeconfig fallback if the
  combined Secret has no kubeconfig. An administrator kubeconfig is never used.

In direct pipeline mode, database passwords remain in memory. Prepared-input mode
also stores passwords in the explicitly created input file. Uploadable kubeconfig and certificate files
are created in a private temporary directory (0700) with file permissions 0600.
Their paths are shown after registration review. They are removed when the browser
session ends, including normal failures and interrupt handling. A forced process
kill or machine crash may leave a `sap-edge-browser-*` directory in the system
temporary directory; remove that directory after the session is no longer needed.

## Add the remaining deployment flow

After the walkthrough, put the reviewed, parameterized JavaScript module under
this directory and use:

```bash
npm run sap:browser -- run \
  --url "$SAP_ELM_URL" --flow hack/sap-browser/YOUR-FLOW.mjs \
  --context YOUR_PIPELINE_CLUSTER_CONTEXT \
  --namespace YOUR_PIPELINE_NAMESPACE --pipeline-run YOUR_PIPELINE_RUN
```

A flow exports `async run(args)` and `async verify(args)`. Both receive:

| Argument | Contents |
| --- | --- |
| `page`, `context` | Authenticated Playwright page and browser context |
| `inputs.clusterName`, `inputs.pipelineRun` | Selected cluster and run |
| `inputs.postgres` | `host`, `port`, `database`, `username`, `password` |
| `inputs.datastore` | `type`, `address`, `password`, `serverName`, `mode`, `username` |
| `files` | `kubeconfig`, `postgresCA`, `datastoreCA` upload paths |
| `waitForLogin()` | Wait again for the ELM Edge Nodes page after interactive login |

Use these values in recorded `fill()` and `setInputFiles()` calls. Keep selectors
based on actual form labels. Inspect existing edge nodes/deployments before
creating them and wait for actual ready states. `verify()` must return `true` only
when the intended ELM/EIC deployment and test iFlows are ready; returning from
`run()` alone is not success. Flow code has access to credentials and local files,
so only run a local module you have reviewed.

After successful verification, approve the existing Tekton gate to continue the
cluster checks and endpoint tests. This helper never approves it automatically.

## Verification

```bash
npm run sap:browser:test
# Or use the installed Chrome for the isolated browser fixture:
SAP_BROWSER_TEST_CHANNEL=chrome npm run sap:browser:test
```

Tests cover run/Secret association, Redis/Valkey input mapping, missing values,
prepared-input collection/loading, private-file cleanup on failure, and real browser interaction with a local wizard
fixture including duplicate detection and the boundary before submission. They
do not access SAP or Kubernetes and do not prove a full live deployment.

Reference: [Playwright Inspector and recording](https://playwright.dev/docs/codegen).
