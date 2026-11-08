// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words domcontentloaded PWDEBUG

// The pipeline browser session shared by the platforms. A profile supplies what differs:
//   { name, options(env), sessionLimitMinutes, hub: 'skip' | 'ignore',
//     loadInputs(read, options, { dir }), loadCells(read, options, { waitForTask, dir }),
//     loadKubeconfig(read, options), leftoverPolicy, meshTask, handOverFolders(options) }
// options(env) returns at least: mode, phase, url, namespace, pipelineRun, pipelineRunUID,
// clusterName, podName, podUID, taskRunName, serviceAccount, s3Prefix, clusterEdgeNodeId,
// sessionMinutes, loginMinutes, directory, bucket ({ endpoint, name, credentials } or
// undefined) and, for the upgrade phase, upgradeVersion.

import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { chromium } from 'playwright';
import { inClusterClient } from './cluster-reader.mjs';
import { fetchElmCli, runElmInit } from './elm-cli.mjs';
import { runDeployFlow, runTeardownFlow, runUpgradeFlow } from './elm-flow.mjs';
import { contextPassword, elmPages } from './elm-pages.mjs';
import { SetupError } from './inputs.mjs';
import { isPages } from './is-pages.mjs';
import { waitForPipelineTask } from './milestones.mjs';
import { openRoute, routeName } from './route.mjs';
import { s3Client } from './s3.mjs';
import { waitForFinish, writeStatus } from './session.mjs';

export const PHASES = ['deploy', 'upgrade', 'teardown'];
const flowOutcomes = {
  deploy: ['deployed'],
  upgrade: ['upgraded', 'nothing-to-upgrade'],
  teardown: ['edge-node-deleted', 'nothing-to-delete'],
};
// Real ELM operations take minutes: poll every 20 s.
const POLL_MS = 20000;

function joinWords(words, conjunction) {
  return words.length < 2 ? words.join('') : `${words.slice(0, -1).join(', ')} ${conjunction} ${words.at(-1)}`;
}

export function browserPhase(env, phases = PHASES) {
  const phase = env.SAP_BROWSER_PHASE || 'deploy';
  if (!phases.includes(phase)) throw new SetupError(`SAP browser phase must be ${joinWords(phases, 'or')}.`);
  return phase;
}

const namePattern = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;

// The run, pod and ELM URL every platform's options start from.
export function pipelinePodOptions(env) {
  const mode = env.SAP_BROWSER_MODE;
  if (!['inspect', 'auto'].includes(mode)) throw new SetupError('SAP browser mode must be inspect or auto.');
  let url;
  try { url = new URL(env.SAP_ELM_URL); } catch { throw new SetupError('Set sapElmUrl to the ELM HTTPS URL.'); }
  if (url.protocol !== 'https:' || url.username || url.password) throw new SetupError('Use an ELM HTTPS URL without credentials.');
  for (const key of ['PIPELINE_NAMESPACE', 'PIPELINE_RUN', 'POD_NAME', 'TASKRUN_NAME', 'RUNNER_SERVICE_ACCOUNT', 'POD_SERVICE_ACCOUNT']) {
    if (!namePattern.test(env[key] ?? '')) throw new SetupError(`Missing or invalid ${key}.`);
  }
  // Without the run file's taskRunSpecs the pod runs as the pipeline SA, which
  // cannot read the PipelineRun or create the Route: stop before anything else.
  if (env.POD_SERVICE_ACCOUNT !== env.RUNNER_SERVICE_ACCOUNT) {
    throw new SetupError(`The browser pod runs as ${env.POD_SERVICE_ACCOUNT}, not ${env.RUNNER_SERVICE_ACCOUNT}: add the taskRunSpecs from the run file.`);
  }
  for (const key of ['PIPELINE_RUN_UID', 'POD_UID']) {
    if (!/^[a-zA-Z0-9-]+$/.test(env[key] ?? '')) throw new SetupError(`Missing or invalid ${key}.`);
  }
  if (env.PWDEBUG || env.DEBUG?.includes('pw:')) throw new SetupError('Disable Playwright debug logging before handling credentials.');
  return {
    mode, url: url.href, namespace: env.PIPELINE_NAMESPACE,
    pipelineRun: env.PIPELINE_RUN, pipelineRunUID: env.PIPELINE_RUN_UID,
    podName: env.POD_NAME, podUID: env.POD_UID, taskRunName: env.TASKRUN_NAME,
    serviceAccount: env.RUNNER_SERVICE_ACCOUNT,
    // '' (no node id on the cluster) and 'unknown' (could not read it) mean different things to the flow.
    clusterEdgeNodeId: env.CLUSTER_EDGE_NODE_ID ?? '',
    directory: env.SAP_BROWSER_SESSION_DIR || '/tmp/sap-browser-session',
  };
}

// The ObjectBucketClaim's bucket; extraKeys are further secrets the caller needs with it.
export function bucketOptions(env, { extraKeys = [], purpose }) {
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(env.BUCKET_HOST ?? '')) throw new SetupError('Missing or invalid BUCKET_HOST.');
  const port = Number(env.BUCKET_PORT);
  if (!/^[0-9]{1,5}$/.test(env.BUCKET_PORT ?? '') || port < 1 || port > 65535) throw new SetupError('Missing or invalid BUCKET_PORT.');
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(env.BUCKET_NAME ?? '')) throw new SetupError('Missing or invalid BUCKET_NAME.');
  for (const key of ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', ...extraKeys]) {
    if (!env[key]?.trim()) throw new SetupError(`Missing ${key}; ${purpose} needs it.`);
  }
  return {
    endpoint: `https://${env.BUCKET_HOST}:${port}`,
    name: env.BUCKET_NAME,
    credentials: { accessKeyId: env.AWS_ACCESS_KEY_ID, secretAccessKey: env.AWS_SECRET_ACCESS_KEY },
  };
}

function limitMessage(limitMinutes) {
  return `Session must be 1-${limitMinutes} minutes; login time must fit inside the session.`;
}

export function sessionLimits(env, { limitMinutes, defaultMinutes }) {
  const sessionMinutes = Number(env.SAP_BROWSER_SESSION_MINUTES || defaultMinutes);
  const loginMinutes = Number(env.SAP_BROWSER_LOGIN_MINUTES || 30);
  if (!Number.isFinite(sessionMinutes) || sessionMinutes < 1 || sessionMinutes > limitMinutes ||
      !Number.isFinite(loginMinutes) || loginMinutes < 1 || loginMinutes > sessionMinutes) {
    throw new SetupError(limitMessage(limitMinutes));
  }
  return { sessionMinutes, loginMinutes };
}

// Chromium gets only what it needs for the virtual display. Playwright would otherwise pass
// process.env, and anyone viewing the shared noVNC session could open file:///proc/self/environ
// and show the bucket key and the Postgres admin password.
const chromiumEnvKeys = ['DISPLAY', 'PATH', 'HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ'];

export function chromiumLaunchOptions(env = process.env) {
  const browserEnv = {};
  for (const key of chromiumEnvKeys) {
    if (env[key] !== undefined) browserEnv[key] = env[key];
  }
  return { headless: false, args: ['--window-size=1440,900'], env: browserEnv };
}

// A failure inside the deploy/upgrade/teardown flow: the browser stays open for the user.
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

function handOverHint(phase, options, folders) {
  const uploads = joinWords(folders.map((folder) => `${options.s3Prefix}${folder}`), 'and');
  if (phase === 'deploy') {
    return `The browser stays open: finish the ELM steps by hand (here or in your own browser) and upload the zips to ${uploads} in the bucket.`;
  }
  if (phase === 'upgrade') {
    return `The browser stays open: finish the EIC upgrade in ELM by hand and upload new zips to ${uploads} in the bucket.`;
  }
  return `The browser stays open: delete the Edge Node ${options.clusterName} in ELM by hand.`;
}

async function runSession(env, deps, profile, log, logError) {
  if (profile.hub === 'skip' && env.HUB_KUBECONFIG_SECRET_NAME?.trim()) {
    log('hubKubeconfigSecretName is set: the browser automation reads this namespace only and does not support a hub. Continue on the manual path.');
    return 'skipped-hub';
  }
  const options = profile.options(env);
  if (!(options.sessionMinutes >= 1 && options.sessionMinutes <= profile.sessionLimitMinutes)) {
    throw new SetupError(limitMessage(profile.sessionLimitMinutes));
  }
  if (!flowOutcomes[options.phase]) throw new SetupError(`SAP browser phase must be ${joinWords(PHASES, 'or')}.`);
  const {
    openRoute: openRouteFor = openRoute,
    launchBrowser = () => chromium.launch(chromiumLaunchOptions()),
    s3Factory = s3Client,
    steps = elmPages,
    isSteps = isPages,
    waitForPipelineTask: waitForTask = waitForPipelineTask,
    fetchElmCli: fetchElm = fetchElmCli,
    runElmInit: elmInit = runElmInit,
    contextPassword: newPassword = contextPassword,
    pollMs = POLL_MS,
    finishInterval,
  } = deps;
  const flows = { deploy: runDeployFlow, upgrade: runUpgradeFlow, teardown: runTeardownFlow, ...deps.flows };
  const client = deps.client ?? inClusterClient(options.namespace);
  const read = (kind, name) => client.get(kind, name);
  const { directory, mode, phase, clusterName, pipelineRun, pipelineRunUID, s3Prefix } = options;
  const metadata = { mode, phase, pipelineRun, clusterName };
  const recordKey = `${s3Prefix}.browser/edge-node.json`;

  const sessionEnd = Date.now() + options.sessionMinutes * 60000;
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
  let s3;

  const pause = async (ms) => {
    try {
      await delay(ms, undefined, { signal: abort.signal });
    } catch (error) {
      if (abort.signal.aborted) throw abort.signal.reason;
      throw error;
    }
  };

  const objectExists = async (key) => (await s3.list(key)).some((object) => object.key === key);

  // The node this run created in ELM; teardown deletes only that node.
  const recordNode = async ({ name, elmId }) => {
    const file = join(workDir, 'edge-node.json');
    await writeFile(file, JSON.stringify({ name, elmId }) + '\n', { mode: 0o600 });
    await s3.put(file, recordKey);
  };

  const readNodeRecord = async () => {
    if (!s3) throw new SetupError('No bucket for the Edge Node ownership record in this phase; remove the Edge Node by hand.');
    if (!await objectExists(recordKey)) return null;
    const file = join(workDir, 'edge-node-record.json');
    await rm(file, { force: true });
    await s3.get(recordKey, file);
    let record;
    try {
      record = JSON.parse(await readFile(file, 'utf8'));
    } catch {
      throw new SetupError('The Edge Node ownership record in the bucket is not valid; continue manually.');
    }
    if (typeof record?.name !== 'string' || !['string', 'number'].includes(typeof record.elmId)) {
      throw new SetupError('The Edge Node ownership record in the bucket is not valid; continue manually.');
    }
    // A record for another node name is not this run's record.
    return record.name === clusterName ? record : null;
  };

  const waitForMarker = async (key) => {
    log(`Waiting for the pipeline to apply the resources (${key}).`);
    while (!await objectExists(key)) {
      abort.signal.throwIfAborted();
      await pause(pollMs);
    }
  };

  // After the wait the status returns to resumeState: 'automating' once the browser runs.
  const waitForPipeline = async (pipelineTaskName, resumeState = 'automating') => {
    abort.signal.throwIfAborted();
    log(`Waiting for pipeline task ${pipelineTaskName}.`);
    await writeStatus(directory, 'waiting-for-pipeline', { ...metadata, pipelineTask: pipelineTaskName });
    await waitForTask(read, { pipelineRun, pipelineRunUID, pipelineTaskName, signal: abort.signal });
    await writeStatus(directory, resumeState, metadata);
  };

  const loadCells = (resumeState) => profile.loadCells(read, options, {
    waitForTask: (pipelineTaskName) => waitForPipeline(pipelineTaskName, resumeState), dir: workDir,
  });

  const handOver = async (error) => {
    await writeStatus(directory, 'failed', metadata);
    logError('Browser automation stopped before it finished.');
    logError(describe(error));
    log(handOverHint(phase, options, profile.handOverFolders(options)));
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
    let cells;
    if (mode === 'auto') {
      await writeStatus(directory, 'loading-inputs', metadata);
      // Only the deploy needs the run's credentials; upgrade and teardown need the node name.
      inputs = phase === 'deploy' ? await profile.loadInputs(read, options, { dir: workDir }) : { clusterName };
      if (options.bucket) {
        s3 = s3Factory({
          endpoint: options.bucket.endpoint, bucket: options.bucket.name,
          credentials: options.bucket.credentials, home: workDir,
        });
      } else if (phase !== 'teardown') {
        throw new SetupError(`The ${phase} phase needs the bucket.`);
      }
      // Before the browser exists, waits for pipeline tasks return to loading-inputs.
      if (phase !== 'deploy') cells = await loadCells('loading-inputs');
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

    // SAP ended the session mid-flow: the user logs in again, then the flow retries its step.
    const relogin = async () => {
      log('SAP ended the session: log in to SAP again in the browser shown.');
      await writeStatus(directory, 'waiting-for-login', metadata);
      await waitForLogin(page, options);
      await writeStatus(directory, 'automating', metadata);
    };
    const common = {
      page, steps, inputs, s3, s3Prefix, dir: workDir, waitForLogin: relogin, log,
      pollMs, timeoutMs: Math.max(sessionEnd - Date.now(), 0),
    };

    await writeStatus(directory, 'automating', metadata);
    let outcome;
    try {
      if (phase === 'deploy') {
        outcome = await flows.deploy({
          ...common,
          isSteps,
          clusterEdgeNodeId: options.clusterEdgeNodeId,
          leftoverPolicy: profile.leftoverPolicy,
          meshTask: profile.meshTask,
          loadCells: () => loadCells(),
          waitForTask: (pipelineTaskName) => waitForPipeline(pipelineTaskName),
          loadKubeconfig: () => profile.loadKubeconfig(read, options),
          fetchElm: (dir) => fetchElm(s3, dir, { downloadInBrowser: () => steps.downloadElmCli(page, { dir }) }),
          elmInit: (elmOptions) => elmInit({ ...elmOptions, log }),
          password: newPassword(),
          recordNode,
          readNodeRecord,
        });
      } else if (phase === 'upgrade') {
        outcome = await flows.upgrade({ ...common, cells, version: options.upgradeVersion ?? '', waitForMarker });
      } else {
        outcome = await flows.teardown({ ...common, cells, readNodeRecord });
      }
    } catch (error) {
      throw new FlowFailure(error);
    }
    if (!flowOutcomes[phase].includes(outcome)) {
      throw new FlowFailure(new SetupError('The browser flow did not produce a valid outcome.'));
    }
    return outcome;
  };

  try {
    if (mode === 'auto') {
      // Downloads, the restricted kubeconfig, context.cfg and the node record stay in this folder only.
      workDir = await mkdtemp(join(directory, `${profile.name}-work-`));
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

// Never rejects: the browser task always exits 0 and reports its outcome in the result
// file, so the pipeline continues on the manual path after any failure.
export async function runBrowserTask(env, deps, profile) {
  const log = deps.log ?? console.log;
  const logError = deps.logError ?? console.error;
  let outcome;
  try {
    outcome = await runSession(env, deps, profile, log, logError);
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
