// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { chmod, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { browserPhase, bucketOptions, pipelinePodOptions, runBrowserTask, sessionLimits } from './browser-session.mjs';
import { decodeSecret, serviceInputs, SetupError } from './inputs.mjs';
import { loadRestrictedKubeconfig } from './roks-inputs.mjs';

export { chromiumLaunchOptions } from './browser-session.mjs';

const HCP_SESSION_LIMIT_MINUTES = 600;
const SINGLE_PIPELINE = 'hcp-ossm3-validation-pipeline';
const DEDICATED_PIPELINE = 'hcp-ossm3-dedicated-validation-pipeline';
const DATASTORE_TYPES = ['redis', 'valkey-standalone', 'valkey-cluster'];
const kubernetesName = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
const versionPattern = /^(?:[0-9A-Za-z][0-9A-Za-z.+-]*)?$/;
// The only credential Secret keys the session decodes; never the kubeconfig key.
const CREDENTIAL_KEYS = [
  'postgres-host', 'postgres-port', 'postgres-dbname', 'postgres-user', 'postgres-password', 'postgres-tls-root-cert',
  'redis-address', 'redis-password', 'redis-server-name', 'redis-tls-cert',
  'valkey-address', 'valkey-password', 'valkey-mode', 'valkey-server-name', 'valkey-tls-cert',
  'ingress-domain',
];
const REGISTRY_KEYS = ['registry', 'username', 'password', 'ca.crt'];

function flag(env, key) {
  const value = env[key] || 'false';
  if (!['true', 'false'].includes(value)) throw new SetupError(`${key} must be true or false.`);
  return value === 'true';
}

export function hcpPipelineOptions(env) {
  const pod = pipelinePodOptions(env);
  const phase = browserPhase(env);
  if (!/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(env.HOSTED_CLUSTER_NAME ?? '')) throw new SetupError('Missing or invalid HOSTED_CLUSTER_NAME.');
  if (!/^restricted-resources\/[a-z0-9][a-z0-9.-]*\/$/.test(env.S3_PREFIX ?? '')) {
    throw new SetupError('S3_PREFIX must be restricted-resources/<folder>/.');
  }
  // '' is the single-EIC pipeline; 1-9 cells the dedicated one.
  if (!/^[1-9]?$/.test(env.CELL_COUNT ?? 'unset')) throw new SetupError('CELL_COUNT must be empty (single EIC) or 1-9.');
  if (!DATASTORE_TYPES.includes(env.DATASTORE_TYPE)) throw new SetupError(`DATASTORE_TYPE must be ${DATASTORE_TYPES.join(', ')}.`);
  if (!/^pr-[0-9]+$/.test(env.DEPLOYMENT_NAME_PREFIX ?? '')) throw new SetupError('DEPLOYMENT_NAME_PREFIX must be pr-<number>.');
  const solution = env.SAP_EIC_SOLUTION ?? '';
  if (solution.length > 100 || /[\p{Cc}]/u.test(solution)) throw new SetupError('Invalid SAP_EIC_SOLUTION.');
  for (const key of ['SAP_EIC_INSTALL_VERSION', 'SAP_EIC_UPGRADE_VERSION']) {
    if (!versionPattern.test(env[key] ?? '') || (env[key] ?? '').length > 40) throw new SetupError(`Invalid ${key}.`);
  }
  const sharedFsStorageClass = env.SHARED_FS_STORAGE_CLASS || 'nfs-rwx';
  if (!kubernetesName.test(sharedFsStorageClass)) throw new SetupError('Invalid SHARED_FS_STORAGE_CLASS.');
  const { sessionMinutes, loginMinutes } = sessionLimits(env, { limitMinutes: HCP_SESSION_LIMIT_MINUTES, defaultMinutes: 360 });
  const options = {
    ...pod, phase, clusterName: env.HOSTED_CLUSTER_NAME, s3Prefix: env.S3_PREFIX,
    cellCount: env.CELL_COUNT ? Number(env.CELL_COUNT) : 0,
    datastoreType: env.DATASTORE_TYPE,
    highAvailability: flag(env, 'HIGH_AVAILABILITY'),
    proxy: flag(env, 'PROXY_CONFIGURED'),
    deploymentPrefix: env.DEPLOYMENT_NAME_PREFIX,
    solution, keyAlias: env.SAP_EIC_KEY_ALIAS ?? '', sharedFsStorageClass,
    installVersion: env.SAP_EIC_INSTALL_VERSION ?? '', upgradeVersion: env.SAP_EIC_UPGRADE_VERSION ?? '',
    registrySecret: env.REGISTRY_SECRET ?? '',
    sessionMinutes, loginMinutes,
  };
  // Every automated phase reads the cells and the bucket (teardown: the ownership record).
  if (pod.mode === 'auto') {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(options.keyAlias)) throw new SetupError('Missing or invalid SAP_EIC_KEY_ALIAS.');
    if (phase === 'deploy' && !kubernetesName.test(options.registrySecret)) throw new SetupError('Missing or invalid REGISTRY_SECRET.');
    options.bucket = bucketOptions(env, { purpose: 'the auto mode' });
  }
  return options;
}

// Single EIC: one cell without suffixes; dedicated: cells 1..cellCount with -N suffixes.
function cellNames(options) {
  if (!options.cellCount) {
    return [{ suffix: '', task: 'get-all-accesses', secret: `eic-credentials-hcp-${options.clusterName}`, host: 'eic' }];
  }
  return Array.from({ length: options.cellCount }, (_, index) => ({
    suffix: `-${index + 1}`,
    task: `cell${index + 1}-get-all-accesses`,
    secret: `eic-credentials-hcp-${options.clusterName}-eic-${index + 1}`,
    host: `eic-${index + 1}`,
  }));
}

function waitedTasks(options) {
  return ['generate-sa-based-kubeconfig', ...cellNames(options).map((cell) => cell.task), 'configure-mesh-eic'];
}

// This run, its cluster and the pipeline the cell count belongs to. Pipelines as Code
// embeds the pipeline (no pipelineRef): then the embedded spec must hold the tasks
// this session waits for.
async function checkRun(read, options) {
  const run = await read('pipelinerun', options.pipelineRun);
  if (run.metadata?.uid !== options.pipelineRunUID) throw new SetupError('PipelineRun UID does not match this browser task.');
  const hostedClusterName = run.spec?.params?.find((entry) => entry.name === 'hostedClusterName')?.value;
  if (hostedClusterName !== options.clusterName) throw new SetupError('Cluster name does not match this browser task.');
  const expected = options.cellCount ? DEDICATED_PIPELINE : SINGLE_PIPELINE;
  const cellCount = options.cellCount ? `cellCount ${options.cellCount}` : 'An empty cellCount';
  const pipeline = run.spec?.pipelineRef?.name;
  if (pipeline !== undefined) {
    if (pipeline !== expected) throw new SetupError(`${cellCount} needs ${expected}; this run uses another pipeline.`);
    return;
  }
  const tasks = new Set((run.spec?.pipelineSpec?.tasks ?? []).map((task) => task.name));
  const missing = waitedTasks(options).filter((name) => !tasks.has(name));
  if (missing.length) {
    throw new SetupError(`${cellCount} needs ${expected}; this run's pipeline has no task ${missing.join(', ')}.`);
  }
}

function required(data, key, secretName) {
  const value = data[key];
  if (typeof value !== 'string' || !value.trim() || value === 'N/A' || value.includes('N/A:')) {
    throw new SetupError(`Secret ${secretName} has no usable ${key}.`);
  }
  return value;
}

// Decodes only the listed keys: other keys (the admin kubeconfig) are never touched.
async function readKeys(read, name, keys) {
  const secret = await read('secret', name);
  const data = {};
  for (const key of keys) {
    const value = secret.data?.[key];
    if (value !== undefined) data[key] = value;
  }
  return decodeSecret({ data });
}

async function writePrivate(file, content) {
  await writeFile(file, content, { mode: 0o600 });
  // writeFile keeps the mode of a file that already exists.
  await chmod(file, 0o600);
  return file;
}

async function loadHcpInputs(read, options, { dir }) {
  await checkRun(read, options);
  const name = options.registrySecret;
  const data = await readKeys(read, name, REGISTRY_KEYS);
  return {
    clusterName: options.clusterName,
    pipelineRun: options.pipelineRun,
    highAvailability: options.highAvailability,
    proxy: options.proxy,
    registry: {
      url: required(data, 'registry', name),
      username: required(data, 'username', name),
      password: required(data, 'password', name),
      caCertificateFile: await writePrivate(join(dir, 'registry-ca.crt'), required(data, 'ca.crt', name)),
    },
  };
}

async function loadHcpCells(read, options, { waitForTask, dir }) {
  await checkRun(read, options);
  const { datastoreType, deploymentPrefix } = options;
  const cells = [];
  for (const { suffix, task, secret, host } of cellNames(options)) {
    await waitForTask(task);
    const data = await readKeys(read, secret, CREDENTIAL_KEYS);
    const domain = data['ingress-domain'];
    if (!domain?.trim()) throw new SetupError(`Secret ${secret} has no ingress-domain; rerun get-all-accesses so it stores the ingress domain.`);
    if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$/.test(domain)) {
      throw new SetupError(`Secret ${secret} has an invalid ingress-domain.`);
    }
    const component = `edge-icell${suffix}`;
    const deployment = `${deploymentPrefix}-eic${suffix}`;
    const datastoreCA = datastoreType === 'redis' ? 'redis-tls-cert' : 'valkey-tls-cert';
    cells.push({
      component,
      deployment,
      eic: {
        solution: options.solution,
        version: options.installVersion,
        namespaces: {
          main: component,
          secrets: `edge-icell-secrets${suffix}`,
          ela: `edge-icell-ela${suffix}`,
          services: `edge-icell-services${suffix}`,
          gateways: `istio-gateways${suffix}`,
        },
        virtualHost: `${host}.${domain}`,
        keyAlias: options.keyAlias,
        sharedFsStorageClass: options.sharedFsStorageClass,
        servicesDeployment: `${deployment}-services`,
        gatewaysDeployment: `${deployment}-gateways`,
      },
      services: serviceInputs(data, datastoreType),
      files: {
        postgresCA: await writePrivate(join(dir, `${component}-postgres-ca.crt`), required(data, 'postgres-tls-root-cert', secret)),
        redisCA: await writePrivate(join(dir, `${component}-datastore-ca.pem`), required(data, datastoreCA, secret)),
      },
    });
  }
  return cells;
}

export const hcpProfile = {
  name: 'hcp',
  options: hcpPipelineOptions,
  sessionLimitMinutes: HCP_SESSION_LIMIT_MINUTES,
  // The hub only hosts the cluster; the session reads the pipeline namespace on eic.
  hub: 'ignore',
  pipelines: [SINGLE_PIPELINE, DEDICATED_PIPELINE],
  loadInputs: loadHcpInputs,
  loadCells: loadHcpCells,
  loadKubeconfig: (read, options) => loadRestrictedKubeconfig(read, options.clusterName),
  leftoverPolicy: 'hand-over',
  meshTask: 'configure-mesh-eic',
  handOverFolders: (options) => ['elm/', ...cellNames(options).map(({ suffix }) => `edge-icell${suffix}/`)],
};

// Never rejects: the HCP browser task always exits 0 and reports its outcome in the
// result file, so the pipeline continues on the manual path after any failure.
export async function main(env = process.env, deps = {}) {
  return runBrowserTask(env, deps, hcpProfile);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  // Exit explicitly so a child process left by an aborted step cannot hold the task open.
  main().finally(() => process.exit(0));
}
