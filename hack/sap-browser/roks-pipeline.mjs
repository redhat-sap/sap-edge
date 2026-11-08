// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG

import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { browserPhase, runBrowserTask, sessionLimits } from './browser-session.mjs';
import { SetupError } from './inputs.mjs';
import { loadRestrictedKubeconfig, loadRoksInputs } from './roks-inputs.mjs';

export { chromiumLaunchOptions } from './browser-session.mjs';

const namePattern = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
const ROKS_SESSION_LIMIT_MINUTES = 240;

export function roksPipelineOptions(env) {
  const mode = env.SAP_BROWSER_MODE;
  if (!['inspect', 'auto'].includes(mode)) throw new SetupError('SAP browser mode must be inspect or auto.');
  // ROKS has no upgrade window.
  const phase = browserPhase(env, ['deploy', 'teardown']);
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
  if (!/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(env.CLUSTER_NAME ?? '')) throw new SetupError('Missing or invalid CLUSTER_NAME.');
  for (const key of ['PIPELINE_RUN_UID', 'POD_UID']) {
    if (!/^[a-zA-Z0-9-]+$/.test(env[key] ?? '')) throw new SetupError(`Missing or invalid ${key}.`);
  }
  const clusterName = env.CLUSTER_NAME;
  const s3Prefix = `restricted-resources/${clusterName}/`;
  if (env.S3_PREFIX !== s3Prefix) throw new SetupError(`S3_PREFIX must be ${s3Prefix}`);
  const { sessionMinutes, loginMinutes } = sessionLimits(env, { limitMinutes: ROKS_SESSION_LIMIT_MINUTES, defaultMinutes: 180 });
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

// The input loaders are injectable for tests (deps.loadRoksInputs, deps.loadRestrictedKubeconfig).
function roksProfileWith({ loadRoksInputs: loadInputs = loadRoksInputs, loadRestrictedKubeconfig: loadKubeconfig = loadRestrictedKubeconfig } = {}) {
  return {
    name: 'roks',
    options: roksPipelineOptions,
    sessionLimitMinutes: ROKS_SESSION_LIMIT_MINUTES,
    hub: 'skip',
    loadInputs: (read, options) => loadInputs(read, options.pipelineRun, {
      expectedRunUID: options.pipelineRunUID, expectedClusterName: options.clusterName, postgresPassword: options.postgresPassword,
    }),
    // One EIC; its form values are not mapped for ROKS yet, so the deploy flow hands over at the EIC step.
    loadCells: async () => [{ component: 'edge-icell', deployment: null, eic: null }],
    loadKubeconfig: (read, options) => loadKubeconfig(read, options.clusterName),
    leftoverPolicy: 'delete',
    meshTask: 'configure-mesh-eic',
    handOverFolders: () => ['elm/', 'edge-icell/'],
  };
}

export const roksProfile = roksProfileWith();

// Never rejects: the ROKS browser task always exits 0 and reports its outcome in the
// result file, so the pipeline continues on the manual path after any failure.
export async function main(env = process.env, deps = {}) {
  return runBrowserTask(env, deps, roksProfileWith(deps));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  // Exit explicitly so a child process left by an aborted step cannot hold the task open.
  main().finally(() => process.exit(0));
}
