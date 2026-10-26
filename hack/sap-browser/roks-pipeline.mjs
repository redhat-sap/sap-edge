// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG domcontentloaded

import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import { inClusterClient } from './cluster-reader.mjs';
import { fetchElmCli, runElmInit } from './elm-cli.mjs';
import { contextPassword, elmPages } from './elm-pages.mjs';
import { SetupError } from './inputs.mjs';
import { waitForPipelineTask } from './milestones.mjs';
import { runDeployFlow, runTeardownFlow } from './roks-flow.mjs';
import { loadRestrictedKubeconfig, loadRoksInputs } from './roks-inputs.mjs';
import { openRoute, routeName } from './route.mjs';
import { s3Client } from './s3.mjs';
import { waitForFinish, writeStatus } from './session.mjs';

const namePattern = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
const flowOutcomes = { deploy: ['deployed'], teardown: ['edge-node-deleted', 'nothing-to-delete'] };

export function roksPipelineOptions(env) {
  const mode = env.SAP_BROWSER_MODE;
  if (!['inspect', 'auto'].includes(mode)) throw new SetupError('SAP browser mode must be inspect or auto.');
  const phase = env.SAP_BROWSER_PHASE;
  if (!['deploy', 'teardown'].includes(phase)) throw new SetupError('SAP browser phase must be deploy or teardown.');
  let url;
  try { url = new URL(env.SAP_ELM_URL); } catch { throw new SetupError('Set sapElmUrl to the ELM HTTPS URL.'); }
  if (url.protocol !== 'https:' || url.username || url.password) throw new SetupError('Use an ELM HTTPS URL without credentials.');
  for (const key of ['PIPELINE_NAMESPACE', 'PIPELINE_RUN', 'POD_NAME', 'TASKRUN_NAME', 'RUNNER_SERVICE_ACCOUNT']) {
    if (!namePattern.test(env[key] ?? '')) throw new SetupError(`Missing or invalid ${key}.`);
  }
  if (!/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(env.CLUSTER_NAME ?? '')) throw new SetupError('Missing or invalid CLUSTER_NAME.');
  for (const key of ['PIPELINE_RUN_UID', 'POD_UID']) {
    if (!/^[a-zA-Z0-9-]+$/.test(env[key] ?? '')) throw new SetupError(`Missing or invalid ${key}.`);
  }
  const clusterName = env.CLUSTER_NAME;
  const s3Prefix = `restricted-resources/${clusterName}/`;
  if (env.S3_PREFIX !== s3Prefix) throw new SetupError(`S3_PREFIX must be ${s3Prefix}`);
  const sessionMinutes = Number(env.SAP_BROWSER_SESSION_MINUTES || 180);
  const loginMinutes = Number(env.SAP_BROWSER_LOGIN_MINUTES || 30);
  if (!Number.isFinite(sessionMinutes) || sessionMinutes < 1 || sessionMinutes > 240 ||
      !Number.isFinite(loginMinutes) || loginMinutes < 1 || loginMinutes > sessionMinutes) {
    throw new SetupError('Session must be 1-240 minutes; login time must fit inside the session.');
  }
  if (env.PWDEBUG || env.DEBUG?.includes('pw:')) throw new SetupError('Disable Playwright debug logging before handling credentials.');
  // The bucket and the admin password are used only by the automated deploy.
  let bucket;
  let postgresPassword;
  if (mode === 'auto' && phase === 'deploy') {
    if (!/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(env.BUCKET_HOST ?? '')) throw new SetupError('Missing or invalid BUCKET_HOST.');
    const port = Number(env.BUCKET_PORT);
    if (!/^[0-9]{1,5}$/.test(env.BUCKET_PORT ?? '') || port < 1 || port > 65535) throw new SetupError('Missing or invalid BUCKET_PORT.');
    if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(env.BUCKET_NAME ?? '')) throw new SetupError('Missing or invalid BUCKET_NAME.');
    for (const key of ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'POSTGRES_ADMIN_PASSWORD']) {
      if (!env[key]?.trim()) throw new SetupError(`Missing ${key}; the auto deploy needs it.`);
    }
    bucket = {
      endpoint: `https://${env.BUCKET_HOST}:${port}`,
      name: env.BUCKET_NAME,
      credentials: { accessKeyId: env.AWS_ACCESS_KEY_ID, secretAccessKey: env.AWS_SECRET_ACCESS_KEY },
    };
    postgresPassword = env.POSTGRES_ADMIN_PASSWORD;
  }
  return {
    mode, phase, url: url.href, namespace: env.PIPELINE_NAMESPACE,
    pipelineRun: env.PIPELINE_RUN, pipelineRunUID: env.PIPELINE_RUN_UID, clusterName,
    podName: env.POD_NAME, podUID: env.POD_UID, taskRunName: env.TASKRUN_NAME,
    serviceAccount: env.RUNNER_SERVICE_ACCOUNT, s3Prefix,
    // '' (no node id on the cluster) and 'unknown' (could not read it) mean different things to the flow.
    clusterEdgeNodeId: env.CLUSTER_EDGE_NODE_ID ?? '',
    sessionMinutes, loginMinutes, bucket, postgresPassword,
    directory: env.SAP_BROWSER_SESSION_DIR || '/tmp/sap-browser-session',
  };
}

// A failure inside the deploy/teardown flow: the browser stays open for the user.
class FlowFailure extends Error {
  constructor(cause) { super('Browser flow failed.', { cause }); }
}

// Never print Playwright messages or stacks: fill() errors can include credentials.
function describe(error) {
  return error instanceof SetupError ? error.message : 'Unexpected error; details are hidden because they can contain credentials.';
}

// Same checks as pipeline.mjs: the ELM origin, then the Edge Nodes heading.
async function waitForLogin(page, options) {
  const origin = new URL(options.url).origin;
  const timeout = options.loginMinutes * 60000;
  try {
    await page.goto(options.url, { waitUntil: 'domcontentloaded' });
  } catch {
    throw new SetupError('Chromium could not open the ELM URL.');
  }
  try {
    await page.waitForURL((url) => url.origin === origin, { timeout });
    await page.getByRole('heading', { name: 'Edge Nodes', exact: true }).waitFor({ state: 'visible', timeout });
  } catch {
    throw new SetupError(`SAP login did not reach the ELM Edge Nodes page (limit ${options.loginMinutes} minutes).`);
  }
  if (new URL(page.url()).origin !== origin) throw new SetupError('Unexpected SAP tenant.');
}

async function runSession(env, deps, log, logError) {
  if (env.HUB_KUBECONFIG_SECRET_NAME?.trim()) {
    log('hubKubeconfigSecretName is set: the browser automation reads this namespace only and does not support a hub. Continue on the manual path.');
    return 'skipped-hub';
  }
  const options = roksPipelineOptions(env);
  const {
    openRoute: openRouteFor = openRoute,
    launchBrowser = () => chromium.launch({ headless: false, args: ['--window-size=1440,900'] }),
    s3Factory = s3Client,
    flows = { deploy: runDeployFlow, teardown: runTeardownFlow },
    steps = elmPages,
    loadRoksInputs: loadInputs = loadRoksInputs,
    waitForPipelineTask: waitForTask = waitForPipelineTask,
    loadRestrictedKubeconfig: loadKubeconfig = loadRestrictedKubeconfig,
    fetchElmCli: fetchElm = fetchElmCli,
    runElmInit: elmInit = runElmInit,
    contextPassword: newPassword = contextPassword,
    finishInterval,
  } = deps;
  const client = deps.client ?? inClusterClient(options.namespace);
  const read = (kind, name) => client.get(kind, name);
  const { directory, mode, phase, clusterName, pipelineRun, pipelineRunUID } = options;
  const metadata = { mode, phase, pipelineRun, clusterName };

  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(new SetupError('Browser session time limit reached.')), options.sessionMinutes * 60000);
  const interrupted = () => abort.abort(new SetupError('Browser session interrupted.'));
  process.once('SIGTERM', interrupted);
  process.once('SIGINT', interrupted);
  const stopped = new Promise((_, reject) => {
    abort.signal.addEventListener('abort', () => reject(abort.signal.reason), { once: true });
  });
  // An abort before the race starts (SIGTERM during mkdtemp) must not be an unhandled rejection.
  stopped.catch(() => {});
  let closing = false;
  let routeOpening;
  let browserLaunching;
  let workDir;

  const handOver = async (error) => {
    await writeStatus(directory, 'failed', metadata);
    logError('Browser automation stopped before it finished.');
    logError(describe(error));
    log(phase === 'deploy'
      ? `The browser stays open: finish the ELM steps by hand (here or in your own browser) and upload the zips to ${options.s3Prefix}elm/ and ${options.s3Prefix}edge-icell/ in the bucket.`
      : `The browser stays open: delete the Edge Node ${clusterName} in ELM by hand.`);
    log('When done, close Chromium or run:');
    log(`oc -n ${options.namespace} exec ${options.podName} -c step-browser -- node /opt/sap-browser/control.mjs finish`);
    try {
      await waitForFinish(directory, abort.signal, finishInterval);
    } catch {
      // Chromium closed, session deadline or interruption: the hand-over ends either way.
    }
    return 'handed-over';
  };

  const session = async () => {
    await rm(join(directory, 'finish'), { force: true });
    let inputs;
    let s3;
    if (mode === 'auto' && phase === 'deploy') {
      await writeStatus(directory, 'loading-inputs', metadata);
      inputs = await loadInputs(read, pipelineRun, {
        expectedRunUID: pipelineRunUID, expectedClusterName: clusterName, postgresPassword: options.postgresPassword,
      });
      s3 = s3Factory({
        endpoint: options.bucket.endpoint, bucket: options.bucket.name,
        credentials: options.bucket.credentials, home: workDir,
      });
    }
    abort.signal.throwIfAborted();
    await writeStatus(directory, 'opening-route', metadata);
    routeOpening = openRouteFor(client, {
      name: routeName(clusterName), podName: options.podName, podUID: options.podUID,
      taskRunName: options.taskRunName, serviceAccount: options.serviceAccount,
    });
    const route = await routeOpening;
    abort.signal.throwIfAborted();
    log(`Open ${route.url}, log in to OpenShift, then log in to SAP in the browser shown.`);
    browserLaunching = launchBrowser();
    const browser = await browserLaunching;
    browser.on('disconnected', () => {
      if (!closing) abort.abort(new SetupError('Chromium was closed before the session finished.'));
    });
    const context = await browser.newContext({ viewport: null });
    context.setDefaultTimeout(30000);
    const page = await context.newPage();
    await writeStatus(directory, 'waiting-for-login', metadata);
    await waitForLogin(page, options);

    if (mode === 'inspect') {
      await writeStatus(directory, 'inspecting', metadata);
      log('Inspector is open after login. Resume Inspector when the walkthrough is finished.');
      log('Recordings can contain entered credentials; keep them private.');
      await page.pause();
      return 'inspection-finished';
    }

    await writeStatus(directory, 'automating', metadata);
    let outcome;
    try {
      outcome = phase === 'deploy'
        ? await flows.deploy({
          page, steps, inputs, clusterEdgeNodeId: options.clusterEdgeNodeId, s3, s3Prefix: options.s3Prefix, dir: workDir,
          waitForTask: async (pipelineTaskName) => {
            abort.signal.throwIfAborted();
            log(`Waiting for pipeline task ${pipelineTaskName}.`);
            await writeStatus(directory, 'waiting-for-pipeline', { ...metadata, pipelineTask: pipelineTaskName });
            await waitForTask(read, { pipelineRun, pipelineRunUID, pipelineTaskName, signal: abort.signal });
            await writeStatus(directory, 'automating', metadata);
          },
          loadKubeconfig: () => loadKubeconfig(read, clusterName),
          fetchElm: (dir) => fetchElm(s3, dir),
          elmInit: (elmOptions) => elmInit({ ...elmOptions, log }),
          password: newPassword(),
          log,
        })
        : await flows.teardown({ page, steps, clusterName, log });
    } catch (error) {
      throw new FlowFailure(error);
    }
    if (!flowOutcomes[phase].includes(outcome)) {
      throw new FlowFailure(new SetupError('The browser flow did not produce a valid outcome.'));
    }
    return outcome;
  };

  try {
    if (mode === 'auto' && phase === 'deploy') {
      // Downloads, the restricted kubeconfig and context.cfg stay in this folder only.
      workDir = await mkdtemp(join(directory, 'roks-work-'));
      await chmod(workDir, 0o700);
    }
    let outcome;
    try {
      // The deadline covers inputs, Route, login, automation and the hand-over.
      outcome = await Promise.race([stopped, session()]);
    } catch (error) {
      // Deadline, interruption or Chromium closed: the session failed, nothing to hand over.
      if (abort.signal.aborted) throw abort.signal.reason;
      if (!(error instanceof FlowFailure)) throw error;
      return await handOver(error.cause);
    }
    await writeStatus(directory, outcome, metadata).catch(() => {});
    return outcome;
  } finally {
    closing = true;
    clearTimeout(timer);
    process.removeListener('SIGTERM', interrupted);
    process.removeListener('SIGINT', interrupted);
    const browser = await browserLaunching?.catch(() => undefined);
    try { await browser?.close(); } catch { /* already gone */ }
    const route = await routeOpening?.catch(() => undefined);
    try { await route?.close(); } catch { /* close() warns on its own */ }
    if (workDir) await rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

// Never rejects: the ROKS browser task always exits 0 and reports its outcome in the
// result file, so the pipeline continues on the manual path after any failure.
export async function main(env = process.env, deps = {}) {
  const log = deps.log ?? console.log;
  const logError = deps.logError ?? console.error;
  let outcome;
  try {
    outcome = await runSession(env, deps, log, logError);
  } catch (error) {
    logError('SAP browser task stopped.');
    logError(describe(error));
    logError('The pipeline run continues on the manual path.');
    outcome = 'failed';
  }
  log(`SAP browser outcome: ${outcome}`);
  if (env.SAP_BROWSER_RESULT_PATH) {
    try {
      await writeFile(env.SAP_BROWSER_RESULT_PATH, outcome, { mode: 0o600 });
    } catch {
      logError('Cannot write the outcome result.');
    }
  }
  return outcome;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  // Exit explicitly so a child process left by an aborted step cannot hold the task open.
  main().finally(() => process.exit(0));
}
