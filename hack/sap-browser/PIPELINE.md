<!--
SPDX-FileCopyrightText: 2026 SAP edge team
SPDX-License-Identifier: Apache-2.0
cspell:words Containerfile ocpxu portforward
-->

# SAP browser automation in the pipelines

`hcp-ossm3-single-eic-validation-pipeline` (one Edge Node with one EIC on HCP KubeVirt) can
drive the SAP Edge Lifecycle Management (ELM) and Integration Suite steps with
Playwright. Chromium runs on a virtual display in a task pod. You reach it
through a per-run Route behind the OpenShift OAuth proxy, log in to OpenShift and
then to SAP in the browser shown, and Playwright continues in that session. The
approval gates stay: the automation never approves one.

**ROKS:** `roks-ossm3-single-eic-validation-pipeline` has its own browser tasks with the same
image; see
[Browser automation (optional)](../../.tekton/README.md#browser-automation-optional)
in `.tekton/README.md`. The rest of this page describes the HCP pipeline.

```text
fetch-repository -> sap-browser-image (runner image; empty when disabled)
wait-cluster-ready -> sap-browser-access (per-run Secret access, proxy check, Edge Node ID)
  -> sap-browser-deploy (session 1): Edge Node, elm/ zip, Embedded Cloud Connector,
       EIC deployment, edge-icell/ zip, resume after configure-mesh-eic, keystore and iFlows
  -> approval-elm-eic-iflow-deployed -> endpoint tests -> approval-teardown
  -> sap-browser-teardown (session 2): EIC deployment and Edge Node deleted
  -> teardown-hosted-cluster (also deletes the per-run Role)
```

The pipeline's own tasks do not wait for the session: `wait-elm-zip` and
`wait-eic-zip` wait for the zips whoever uploads them, and the session waits for
the pipeline (restricted kubeconfig, credentials, mesh) before each step that
needs it.

## Modes

`sapBrowserMode` in the run file:

- `disabled` (default): the browser tasks are skipped, `sap-browser-image` and
  `sap-browser-access` do nothing, and everything is done by hand.
- `inspect`: log in, then Playwright Inspector opens in the browser to record
  screens. Nothing is uploaded or changed in SAP. Recordings can contain entered
  credentials; keep them private.
- `auto`: Playwright runs the steps of the phase. On any problem (a screen it
  does not know, a version ELM does not offer, an Edge Node this run did not
  create) it stops, says why in the log, and leaves the browser open for you.

## Phases

The task `hcp-sap-browser` runs one phase per session:

- `deploy` (`sap-browser-deploy`, starts after `wait-cluster-ready`, so you log
  in while the cluster is set up): add the Edge Node `<hostedClusterName>` with
  restricted access and the registry of the Secret `<hubClusterName>-quay-robot`
  and record it as created by this run, put the ELM zip into `elm/`, wait for
  the restricted kubeconfig, set up the Embedded Cloud Connector, deploy EIC
  (deployment `pr-<number>-eic`, version `sapEicInstallVersion` or the one ELM
  preselects), put the EIC zip into `edge-icell/`, wait for
  `configure-mesh-eic`, resume the deployment, wait until it is successful, then
  deploy the keystore and the test iFlows in Integration Suite and wait until
  they are started.
- `upgrade`: upgrade EIC to `sapEicUpgradeVersion` (empty: nothing to upgrade).
  The single-EIC pipeline does not run this phase yet.
- `teardown` (`sap-browser-teardown`, after `approval-teardown`, second login):
  delete the EIC deployment and remove the Edge Node, but only an Edge Node
  this run created; any other is handed over, never deleted. Skipped with
  `skipTeardown: "true"`: the cluster stays, and so do its ELM entries.

This pipeline uses no proxy: the hub's `<hubClusterName>-proxy-config` Secret
(it exists on `eic` for the proxy test runs) is not consulted. A pipeline with
a proxy variant passes `proxySecretName` to `hcp-sap-browser-access`; such a
proxy run hands over at "Add Edge Node": add it by hand with the proxy settings.

## One-time setup

In the pipeline namespace (`sap-elm-eic-validation` on `eic`):

1. **Runner image.** `sap-browser-image` builds `hack/sap-browser/Containerfile`
   and pushes it to `quay.apps.eic.ocp.sap.local/sap_elm_eic/sap-browser`
   (tag `sap-browser-<content hash>`) when that tag is missing, then checks that
   the cluster nodes can pull it (see
   [SAP browser runner image](../../.tekton/README.md#sap-browser-runner-image)).
   Before the first run, the repository `sap_elm_eic/sap-browser` must exist and
   be public on eic's Quay (pulls need no pull secret), and the robot account of
   the Secret `eic-quay-robot` needs Write on it (its Creator role does not cover
   a repository someone else created). The nodes must trust the Quay CA. If
   the image cannot be provided (tag check, build, push or pull check fails),
   the task logs why, its result stays empty and the run goes on without the
   browser (both sessions skipped, the ELM steps by hand); it never fails the
   run. To use another image, set `sapBrowserImage`; nothing is built or
   checked then.
2. **The two Quay Secrets `<hub>-quay-robot`**, one per hub: `eli-quay-robot`
   and `eic-quay-robot`, with the keys `registry` (the "Local Container Registry
   URL" for "Add Edge Node", for example
   `quay.apps.eli.ocpxu01.sap/sap_elm_eic/eic_validation`), `username`,
   `password` (a robot account with write access to that repository) and
   `ca.crt` (the CA of that Quay's certificate). The deploy session uses the
   Secret of the run's `hubClusterName`, so the hosted cluster pulls the EIC
   images from its own hub. `eic-quay-robot` also pushes the runner image
   (`username`, `password`, `ca.crt`). How to create the robot accounts, the
   runner repository and the Secrets: [Quay setup](#quay-setup).
3. **RBAC:** `oc -n sap-elm-eic-validation apply -f hack/sap-browser/hcp-runner-rbac.yaml`.
   It creates the ServiceAccount `hcp-sap-browser-runner` (gets PipelineRuns and
   TaskRuns, creates and deletes its Route and Service, gets no Secrets
   namespace-wide) and lets the `pipeline` ServiceAccount manage Roles and
   RoleBindings. `sap-browser-access` creates the per-run Role and RoleBinding
   `hcp-sap-browser-<hostedClusterName>`, which grant the runner `get` on this
   run's Secrets only: `edgelm-kubeconfig-generated-<cluster>`,
   `eic-credentials-hcp-<cluster>` and `<hubClusterName>-quay-robot`. Kubernetes
   lets the `pipeline` ServiceAccount grant only what it holds, so it needs `get`
   on these Secrets itself. `teardown-hosted-cluster` deletes the Role and
   RoleBinding. If the OAuth proxy logs 403 on `subjectaccessreviews`, bind
   `system:auth-delegator` to the runner (command in the file).
4. **ELM URL:** the Secret `sap-elm-url` (key `url`, the direct ELM URL
   `https://<tenant>/comsapclmedgelm.comsapclmedgelm/index.html`) keeps the
   tenant out of the repository; `sapElmUrl` in the run file overrides it:

   ```bash
   oc -n sap-elm-eic-validation create secret generic sap-elm-url \
     --from-literal=url="https://<tenant>/comsapclmedgelm.comsapclmedgelm/index.html"
   ```

5. **elm CLI** (optional): the deploy session takes the newest file under
   `tools/elm/` in the OBC bucket (the Linux x86_64 binary, a `.zip` or a
   `.tar.gz`). Without one it downloads the CLI from the SAP Software Download
   Center in the browser and stores it there for later runs.

### Quay setup

Each hub (`eli`, `eic`) has its own Quay. Do steps 1, 3 and 4 for each hub; the
Secrets always go into the pipeline namespace on `eic`, where the pipeline runs.

1. **Robot account.** In the hub's Quay organization (`sap_elm_eic`): Robot
   accounts → Create robot account, for example `elm_eic_validation`, and add it
   to a team with the **Creator** role (or to `owners`). ELM's image replication
   pushes into a new repository per Edge Node below the registry path
   (`eic_validation/<edge node ID>/…`), so Write on existing repositories is not
   enough: the robot must be able to create repositories. Copy its username
   (`sap_elm_eic+elm_eic_validation`) and token (gear menu → View credentials).
2. **Runner repository** (`eic` only). Create the repository
   `sap_elm_eic/sap-browser`, set it to Public, and give the `eic` robot Write
   on it (repository Settings → User and robot permissions): the Creator role
   only covers repositories the robot created itself.
3. **CA of the hub's Quay**, with `oc` logged in to that hub:

   ```bash
   HUB=eli   # or eic
   oc get configmap -n openshift-config-managed default-ingress-cert \
     -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/$HUB-ca.crt
   curl -fsS --cacert /tmp/$HUB-ca.crt https://<hub Quay host>/health/instance && echo "CA ok"
   ```

   If the check fails, the Quay route uses a certificate from another CA;
   export that CA instead.
4. **Secret `<hub>-quay-robot`**, with `oc` logged in to `eic`. The token is
   read without echo and passed as a file, so it ends up neither in the shell
   history nor in the process list (zsh syntax; in bash use
   `read -r -p 'Robot username: ' QUAY_USER` and
   `read -r -s -p 'Robot token: ' QUAY_TOKEN`):

   ```zsh
   HUB=eli
   REGISTRY=quay.apps.eli.ocpxu01.sap/sap_elm_eic/eic_validation   # "Local Container Registry URL"
   read "QUAY_USER?Robot username ($HUB): "
   read -s "QUAY_TOKEN?Robot token ($HUB): "; echo
   oc -n sap-elm-eic-validation create secret generic $HUB-quay-robot \
     --from-literal=registry="$REGISTRY" \
     --from-literal=username="$QUAY_USER" \
     --from-file=password=<(printf %s "$QUAY_TOKEN") \
     --from-file=ca.crt=/tmp/$HUB-ca.crt
   unset QUAY_TOKEN
   # check the keys without printing values
   oc -n sap-elm-eic-validation get secret $HUB-quay-robot -o jsonpath='{.data}' | jq 'map_values(length)'
   ```

   Repeat with `HUB=eic` and `eic`'s registry path
   (`quay.apps.eic.ocp.sap.local/sap_elm_eic/eic_validation`).
5. **Node trust** (`eic`). The runner pods pull the image from `eic`'s Quay. If
   `eic`'s nodes do not trust that CA yet, add it to the cluster's image
   configuration once (`image.config.openshift.io/cluster`,
   `additionalTrustedCA`); `sap-browser-image` reports a pull that fails on the
   certificate.

### Build the image by hand

For `sapBrowserImage` (and for ROKS), from the repository root:

```bash
podman build --platform linux/amd64 -f hack/sap-browser/Containerfile -t "$SAP_BROWSER_IMAGE" .
podman push "$SAP_BROWSER_IMAGE"
```

Use a new tag after each rebuild. The build needs Docker Hub (the `node` base
image), npm, Debian packages and the Playwright browser download; the running
task installs nothing. The helper code comes from the run's checkout
(`hack/sap-browser`), only its dependencies from the image.

Failures before the browser starts (a `sapBrowserImage` that cannot be pulled,
or no ServiceAccount because `hcp-runner-rbac.yaml` was not applied) fail the
task's pod and stop the run, unlike failures inside the browser. A pod-level failure
of `sap-browser-teardown` also skips `teardown-hosted-cluster`: delete the
hosted cluster by hand then.

## Enable it in the run file

In `.tekton-examples/hcp-ossm3-single-eic-validation-run.yaml` (copied to `.tekton/` on a
pull request):

- set `sapBrowserMode` to `inspect` or `auto`;
- set `sapElmUrl` to the direct ELM URL
  (`https://<tenant>/comsapclmedgelm.comsapclmedgelm/index.html`);
- uncomment `taskRunSpecs`: `sap-browser-deploy` and `sap-browser-teardown` run
  as `hcp-sap-browser-runner` (without it the session stops at once with
  outcome `failed`). `sap-browser-image` must keep the default `pipeline`
  ServiceAccount (buildah needs its SCC).

Optional parameters: `sapBrowserHA` (register the Edge Node as highly
available), `sapEicInstallVersion` and `sapEicUpgradeVersion` (a version ELM
does not offer hands over, naming it), `sapEicSolution` (default
`Edge Integration Cell (dev)`), `sapEicKeyAlias` (default `slv-ic`),
`sapBrowserSessionMinutes` (default 360, 1-600; the deploy session spans the
cluster setup and the EIC installation, its task timeout is 11 hours) and
`sapBrowserLoginMinutes` (default 30). The deployment names need the pull
request number (`pr-<number>-eic`), which Pipelines as Code fills in.

## Use it

1. Once `wait-cluster-ready` is done, open the `sap-browser-deploy` log
   (`tkn pipelinerun logs -f <pipelinerun> -t sap-browser-deploy`) and open the
   Route link it prints (Route `sapb-<hostedClusterName>`).
2. Log in to OpenShift (only users allowed to create `pods/portforward` in the
   pipeline namespace get in), then log in to SAP in the browser shown. When SAP
   ends the session ("Sign in again"), the log asks you to log in again and the
   step is retried.
3. Approve `approval-elm-eic-iflow-deployed` once the session has finished
   (the gate waits for it) and the runtime is healthy.
4. After approving `approval-teardown`, open the `sap-browser-teardown` log the
   same way and log in again. `teardown-hosted-cluster` runs after it.

**Outcomes** (result `outcome`, e.g. `tkn taskrun describe <taskrun>`):
`deployed`, `upgraded`, `nothing-to-upgrade`, `edge-node-deleted` or
`nothing-to-delete` (done); `inspection-finished` (inspect mode); `handed-over`
(the automation stopped and you finished by hand); `failed` (setup, login or
session failure). The browser step always exits 0, so check the outcome rather
than the task status.

**Manual fallback:** whatever happens in the browser, the run continues. On a
hand-over the browser stays open with the reason in the log: finish the steps
there or in your own browser, then close Chromium or run the
`oc exec ... -c step-browser -- node /opt/sap-browser/control.mjs finish`
command from the log. Without the browser (`failed`), do the steps by hand:
upload the zips to `elm/` and `edge-icell/` (`wait-elm-zip` and `wait-eic-zip`
wait for them either way) and, before approving the teardown, delete the EIC
deployment and the Edge Node in ELM.

## Security

The browser profile, downloads and the files it uploads live in memory-backed
pod storage and are removed when the session ends. Logs show no Playwright
messages (they can contain entered values), only the automation's own messages.
The runner reads only this run's Secrets, and from `eic-credentials-hcp-<cluster>`
never the `kubeconfig` key. Only the helper code (`hack/sap-browser`, workspace
`subPath`) reaches the browser pod, not the rest of the workspace.

## Local checks

```bash
npm ci
npm run sap:browser:install
npm run sap:browser:test
hack/tekton-tests/run.sh
```

The tests use fakes for ELM, Integration Suite, Kubernetes and S3; the OpenShift
startup, the Route and SAP SSO need a real run.

References: [Playwright containers](https://playwright.dev/docs/docker),
[noVNC](https://novnc.com/info.html),
[Tekton task customization](https://tekton.dev/docs/pipelines/pipelineruns/#specifying-taskrunspecs).
