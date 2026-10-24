<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-License-Identifier: Apache-2.0
cspell:words Containerfile portforward
-->

# Test SAP browser automation inside OpenShift

The optional `sap-browser` task runs after `get-all-accesses` in
`hcp-ossm3-validation-pipeline`. It starts a temporary Chromium desktop in the task
pod. From your RHEL desktop inside Citrix, use `oc port-forward` and open noVNC in
your browser. Enter SAP login/MFA in the displayed Chromium window; Playwright
continues in that same session.

The first implemented flow is **registration review only**. It fills the wizard
and stops before Add Edge Node. EIC initialization, configuration, deployment,
iFlows and readiness checks still require a tenant-specific flow. The existing
`approval-elm-eic-iflow-deployed` gate is always retained, including for `run` mode.

```text
create cluster and dependencies -> get-all-accesses
  -> sap-browser (optional): login -> browser flow -> inspect -> finish session
  -> existing manual approval -> validation and endpoint tests
```

The default `sapBrowserMode: disabled` preserves the manual workflow. A disabled
browser task is skipped and the approval gate still runs. An enabled browser task
that fails blocks dependent tasks. It is not retried automatically.

## Build and install once

Run these from the repository root in the SAP environment. The image build needs
access to the Node base image, npm, Debian packages and Playwright browser downloads.
The running task does not install packages. Use a trusted checkout containing these
changes; they must also be present at the pipeline's Git `revision`.

Set these variables to your namespace and an image registry you can push to:

```bash
export SAP_PIPELINE_NAMESPACE='YOUR_PIPELINE_NAMESPACE'
export SAP_BROWSER_IMAGE='YOUR_REGISTRY/YOUR_PROJECT/sap-browser:dev-1'

podman build --platform linux/amd64 \
  -f hack/sap-browser/Containerfile -t "$SAP_BROWSER_IMAGE" .
podman push "$SAP_BROWSER_IMAGE"

oc -n "$SAP_PIPELINE_NAMESPACE" apply -f hack/sap-browser/runner-rbac.yaml
oc -n "$SAP_PIPELINE_NAMESPACE" apply -f .tekton/tasks/hcp-sap-browser-task.yaml
oc -n "$SAP_PIPELINE_NAMESPACE" apply -f .tekton/pipelines/hcp-ossm3-validation-pipeline.yaml
```

`linux/amd64` assumes your test cluster uses that architecture. Adjust for your
runner nodes when necessary. Use a new image tag or digest after each rebuild.
Docker can also build this Containerfile. For a private registry, give the
`sap-browser-runner` service account the appropriate image pull secret.

The container runs without root, additional capabilities, privileged mode or a
custom SCC. It uses Playwright's default Chromium sandbox configuration and a
temporary virtual display. Validate compatibility with your OpenShift version and
SCC during this first test; do not grant a privileged SCC to work around a failure.

The runner role grants `get` on PipelineRuns, TaskRuns and Secrets in this namespace.
It grants no list, watch, write or approval permissions. Secret names depend on the
cluster name; for a fixed-cluster rehearsal you can restrict the Secret rule using
`resourceNames` for `eic-credentials-hcp-CLUSTER` and
`edgelm-kubeconfig-generated-CLUSTER`. Use the dedicated service account only for
the browser task, not as the service account for the entire HCP pipeline.

## Enable it in a new PipelineRun

Add these entries to your existing PipelineRun, preserving its other parameters:

```yaml
spec:
  taskRunSpecs:
    - pipelineTaskName: sap-browser
      serviceAccountName: sap-browser-runner
  params:
    - name: sapBrowserMode
      value: review-registration
    - name: sapBrowserImage
      value: YOUR_REGISTRY/YOUR_PROJECT/sap-browser:dev-1
    - name: sapElmUrl
      value: https://YOUR-TENANT/comsapclmedgelm.comsapclmedgelm/index.html
    - name: sapBrowserHA
      value: 'false'
```

The example `.tekton-examples/hcp-ossm3-validation-run.yaml` includes commented
entries. Ensure your overall PipelineRun/task timeouts allow time for interactive
login. The browser session defaults to 120 minutes total, with 30 minutes for
login. `sapBrowserSessionMinutes` and `sapBrowserLoginMinutes` can shorten these;
the total limit is 120 minutes. The PipelineTask timeout is three hours, allowing
some scheduling/startup time before the session deadline.

Input selection is automatic: the pipeline passes its name, UID and hosted-cluster
name. The helper verifies them, checks that `get-all-accesses` succeeded for this
run, and checks the generated Secret's timestamp before reading credentials. The
pod needs API access to the pipeline cluster and access to the SAP tenant/identity
provider. These must be tested from the pod; Citrix connectivity alone does not
establish that SAP SSO works from the pod.

## Open and finish the browser session

Find the browser TaskRun using your actual PipelineRun name:

```bash
oc -n "$SAP_PIPELINE_NAMESPACE" get taskruns \
  -l tekton.dev/pipelineRun=YOUR_PIPELINERUN,tekton.dev/pipelineTask=sap-browser

oc -n "$SAP_PIPELINE_NAMESPACE" get taskrun YOUR_BROWSER_TASKRUN \
  -o jsonpath='{.status.podName}'
```

Set `SAP_BROWSER_POD` to that pod name. Its browser-step logs contain the complete
port-forward, status and finish commands with the actual namespace and pod name:

```bash
export SAP_BROWSER_POD='YOUR_BROWSER_POD'
oc -n "$SAP_PIPELINE_NAMESPACE" logs "$SAP_BROWSER_POD" -c step-browser
oc -n "$SAP_PIPELINE_NAMESPACE" port-forward "pod/$SAP_BROWSER_POD" 6080:6080
```

Keep the port-forward terminal open. In the browser **on the same RHEL desktop**,
open `http://127.0.0.1:6080/vnc.html` and click Connect. This is a view of Chromium
inside the task pod. Complete SAP login/MFA there and reach Edge Nodes in its
original tab. Login in another local browser tab does not authenticate the runner.

After Playwright reaches Configuration Review, inspect the form. From a second
terminal on the Citrix desktop:

```bash
oc -n "$SAP_PIPELINE_NAMESPACE" exec "$SAP_BROWSER_POD" -c step-browser -- \
  node /opt/sap-browser/control.mjs status

oc -n "$SAP_PIPELINE_NAMESPACE" exec "$SAP_BROWSER_POD" -c step-browser -- \
  node /opt/sap-browser/control.mjs finish
```

Finishing closes the session and lets the pipeline reach its manual approval gate.
**Registration review is not deployment verification.** Only approve that gate
after the actual EIC and iFlow deployment is ready. To complete remaining setup
manually during a test, you can use the open browser before finishing the session.

For a selector/flow failure, the browser stays open until you finish or the session
expires. Status says `failed`, and finishing still fails the task. A timeout or
cancellation also fails the task. Inspect the page and fix the flow before rerunning;
do not blindly repeat actions that might already have changed SAP state.

noVNC and VNC bind only to loopback inside the pod. This first version creates no
Service or Route. Your Kubernetes login and `pods/portforward` permission control
access; the finish command additionally requires `pods/exec`. No new permissions
are granted to your user by these manifests. A later HTTPS Route needs explicit
authentication and authorization before it can expose a logged-in browser.

The browser profile and temporary upload files live in memory-backed pod storage.
Normal exit removes the session directory. If the container is forcibly killed,
delete the finished pod to discard any remaining memory-backed files. No login
state, trace, screenshot or credential-bearing browser log is exported by default.

## Iterate without recreating the cluster

Use `.tekton-examples/hcp-sap-browser-taskrun.yaml` against an **existing** compatible
PipelineRun whose `get-all-accesses` succeeded and whose credential Secrets still
exist. Read its UID using:

```bash
oc -n "$SAP_PIPELINE_NAMESPACE" get pipelinerun YOUR_PIPELINERUN \
  -o jsonpath='{.metadata.uid}'
```

Copy the TaskRun example, replace every `REPLACE` value, then create it:

```bash
oc -n "$SAP_PIPELINE_NAMESPACE" create -f YOUR_EDITED_TASKRUN.yaml
```

This standalone TaskRun does not create a cluster or resume the original pipeline.
It reads and validates that original run's inputs. Its helper code comes from the
runner image, so rebuild with a new tag after editing selectors/logic. The integrated
PipelineTask uses helper code from its checked-out `source` workspace instead; its
Playwright dependencies still come from the image. Rebuild the image if dependency
versions change, and keep the checkout and image dependencies in sync.

Keep only one active browser session per target cluster. The pipeline's credential
Secrets are named by cluster, so concurrent runs reusing a cluster name are not
supported. Existing registered edge nodes cause the review flow to stop; use
`inspect` to examine them or implement an explicit resume rule in your custom flow.

## Extend the automation

- `review-registration`: fills the existing wizard and stops before submission.
- `inspect`: logs in, opens Playwright Inspector, and allows recording after login.
  Resume Inspector when finished, then use the finish command. Recordings may contain
  entered values; parameterize them before committing. They are not saved automatically.
- `run`: loads the reviewed `.mjs` module specified by `sapBrowserFlow`, relative to
  `hack/sap-browser`. It must export `run(args)` and `verify(args)` as described in
  [README.md](README.md). Verification must return exactly `true`.

The Task result `outcome` distinguishes `registration-reviewed`,
`inspection-finished`, and `deployment-verified`. These results never approve the
pipeline gate automatically. No complete EIC/iFlow flow is included yet.

Local checks:

```bash
npm ci
npm run sap:browser:install
npm run sap:browser:test
```

The tests exercise input association, session failure/finish semantics, readiness
verification and the registration wizard using a local fixture. The container's
OpenShift startup, port-forward path and SAP SSO require the deployment test above.

References: [Playwright containers](https://playwright.dev/docs/docker),
[noVNC](https://novnc.com/info.html),
[Tekton task customization](https://tekton.dev/docs/pipelines/pipelineruns/#specifying-taskrunspecs).
