// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { browserPhase, bucketOptions, pipelinePodOptions, runBrowserTask, sessionLimits } from './browser-session.mjs';
import { SetupError } from './inputs.mjs';
import { loadRestrictedKubeconfig, loadRoksInputs } from './roks-inputs.mjs';

export { chromiumLaunchOptions } from './browser-session.mjs';

const ROKS_SESSION_LIMIT_MINUTES = 240;

export function roksPipelineOptions(env) {
  const pod = pipelinePodOptions(env);
  // ROKS has no upgrade window.
  const phase = browserPhase(env, ['deploy', 'teardown']);
  if (!/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(env.CLUSTER_NAME ?? '')) throw new SetupError('Missing or invalid CLUSTER_NAME.');
  const clusterName = env.CLUSTER_NAME;
  const s3Prefix = `restricted-resources/${clusterName}/`;
  if (env.S3_PREFIX !== s3Prefix) throw new SetupError(`S3_PREFIX must be ${s3Prefix}`);
  const { sessionMinutes, loginMinutes } = sessionLimits(env, { limitMinutes: ROKS_SESSION_LIMIT_MINUTES, defaultMinutes: 180 });
  // The bucket and the admin password are used only by the automated deploy.
  let bucket;
  let postgresPassword;
  if (pod.mode === 'auto' && phase === 'deploy') {
    bucket = bucketOptions(env, { extraKeys: ['POSTGRES_ADMIN_PASSWORD'], purpose: 'the auto deploy' });
    postgresPassword = env.POSTGRES_ADMIN_PASSWORD;
  }
  return { ...pod, phase, clusterName, s3Prefix, sessionMinutes, loginMinutes, bucket, postgresPassword };
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
