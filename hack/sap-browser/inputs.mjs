// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { execFile } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);

// Only these controlled messages may be printed while handling credentials.
export class SetupError extends Error {
  constructor(message) { super(message); this.name = 'SetupError'; }
}

export function kubernetesReader({ context, namespace, cli = 'oc' }) {
  if (!context || !namespace) throw new SetupError('Both --context and --namespace are required.');
  return async (resource, name) => {
    try {
      const { stdout } = await execute(cli, [
        '--context', context, '--namespace', namespace, '--request-timeout=30s',
        'get', resource, name, '-o', 'json',
      ], { timeout: 35000, maxBuffer: 8 * 1024 * 1024 });
      return JSON.parse(stdout);
    } catch {
      // Command errors can contain stdout (including decoded credentials).
      throw new SetupError(`Cannot read ${resource}/${name}. Check the context, namespace, connection and RBAC.`);
    }
  };
}

function parameter(run, name, fallback) {
  return run.spec?.params?.find((entry) => entry.name === name)?.value ?? fallback;
}

function required(data, key) {
  const value = data[key];
  if (typeof value !== 'string' || !value.trim() || value === 'N/A' || value.includes('N/A:')) {
    throw new SetupError(`Required credential field is missing or unavailable: ${key}`);
  }
  return value;
}

export function decodeSecret(secret) {
  return Object.fromEntries(Object.entries(secret.data ?? {}).map(([key, value]) => {
    if (typeof value !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
      throw new SetupError(`Invalid base64 in Secret field: ${key}`);
    }
    return [key, Buffer.from(value, 'base64').toString('utf8')];
  }));
}

export function serviceInputs(data, datastoreType) {
  if (!['redis', 'valkey-standalone', 'valkey-cluster'].includes(datastoreType)) {
    throw new SetupError('Unsupported datastoreType in PipelineRun.');
  }
  const prefix = datastoreType === 'redis' ? 'redis' : 'valkey';
  return {
    postgres: {
      host: required(data, 'postgres-host'),
      port: required(data, 'postgres-port'),
      database: required(data, 'postgres-dbname'),
      username: required(data, 'postgres-user'),
      password: required(data, 'postgres-password'),
    },
    datastore: {
      type: datastoreType,
      address: required(data, `${prefix}-address`),
      password: required(data, `${prefix}-password`),
      serverName: required(data, `${prefix}-server-name`),
      mode: prefix === 'valkey' ? required(data, 'valkey-mode') : 'standalone',
      username: '',
    },
  };
}

export async function loadInputs(read, pipelineRun, { expectedRunUID, expectedClusterName } = {}) {
  const run = await read('pipelinerun', pipelineRun);
  if (expectedRunUID && run.metadata?.uid !== expectedRunUID) {
    throw new SetupError('PipelineRun UID does not match this browser task.');
  }
  if (run.spec?.pipelineRef?.name !== 'hcp-ossm3-validation-pipeline') {
    throw new SetupError('This helper currently supports hcp-ossm3-validation-pipeline only.');
  }
  const clusterName = parameter(run, 'hostedClusterName');
  if (typeof clusterName !== 'string' || !/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(clusterName)) {
    throw new SetupError('PipelineRun has no valid hostedClusterName.');
  }
  if (expectedClusterName && clusterName !== expectedClusterName) {
    throw new SetupError('Cluster name does not match this browser task.');
  }
  const taskRef = run.status?.childReferences?.find((child) =>
    child.pipelineTaskName === 'get-all-accesses' && child.kind === 'TaskRun');
  if (!taskRef) throw new SetupError('PipelineRun has not reached get-all-accesses yet.');
  const task = await read('taskrun', taskRef.name);
  const ownedByRun = task.metadata?.ownerReferences?.some((owner) => owner.uid === run.metadata?.uid);
  const succeeded = task.status?.conditions?.some((condition) =>
    condition.type === 'Succeeded' && condition.status === 'True');
  if (!ownedByRun || !succeeded) throw new SetupError('get-all-accesses must succeed for this PipelineRun first.');

  const secret = await read('secret', `eic-credentials-hcp-${clusterName}`);
  // The pipeline deletes/recreates this Secret. Reject data from an earlier/later run.
  const created = Date.parse(secret.metadata?.creationTimestamp);
  const started = Date.parse(task.status?.startTime);
  const completed = Date.parse(task.status?.completionTime);
  if (![created, started, completed].every(Number.isFinite) || created < started || created > completed) {
    throw new SetupError('Credential Secret does not belong to the get-all-accesses time window. Check for a reused cluster name.');
  }
  const data = decodeSecret(secret);
  const restricted = data.kubeconfig ? required(data, 'kubeconfig') : required(
    decodeSecret(await read('secret', `edgelm-kubeconfig-generated-${clusterName}`)), 'kubeconfig');
  const datastoreType = parameter(run, 'datastoreType', 'redis');
  return {
    clusterName,
    pipelineRun,
    ...serviceInputs(data, datastoreType),
    attachments: {
      kubeconfig: restricted,
      postgresCA: required(data, 'postgres-tls-root-cert'),
      datastoreCA: required(data, datastoreType === 'redis' ? 'redis-tls-cert' : 'valkey-tls-cert'),
    },
  };
}

export async function withPrivateFiles(inputs, action, directory = tmpdir()) {
  const folder = await mkdtemp(join(directory, 'sap-edge-browser-'));
  try {
    await chmod(folder, 0o700);
    const files = {};
    for (const [key, filename] of Object.entries({
      kubeconfig: 'edgelm-kubeconfig.yaml',
      postgresCA: 'postgres-ca.crt',
      datastoreCA: 'datastore-ca.pem',
    })) {
      files[key] = join(folder, filename);
      await writeFile(files[key], inputs.attachments[key], { mode: 0o600, flag: 'wx' });
    }
    return await action(files);
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
}

function validatePreparedInputs(bundle) {
  if (!bundle || bundle.version !== 1 || !Number.isFinite(Date.parse(bundle.preparedAt))) {
    throw new SetupError('Unsupported or invalid prepared-inputs file.');
  }
  const inputs = bundle.inputs;
  if (!inputs || !/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(inputs.clusterName ?? '')) {
    throw new SetupError('Prepared inputs must identify a valid cluster.');
  }
  required(inputs, 'pipelineRun');
  for (const [section, fields] of Object.entries({
    postgres: ['host', 'port', 'database', 'username', 'password'],
    datastore: ['type', 'address', 'password', 'serverName', 'mode'],
    attachments: ['kubeconfig', 'postgresCA', 'datastoreCA'],
  })) {
    if (!inputs[section] || typeof inputs[section] !== 'object') {
      throw new SetupError(`Prepared inputs are missing section: ${section}`);
    }
    for (const field of fields) required(inputs[section], field);
  }
  if (!['redis', 'valkey-standalone', 'valkey-cluster'].includes(inputs.datastore.type)) {
    throw new SetupError('Unsupported datastore type in prepared inputs.');
  }
  if (!['standalone', 'cluster'].includes(inputs.datastore.mode) || inputs.datastore.username !== '') {
    throw new SetupError('Invalid datastore settings in prepared inputs.');
  }
  return inputs;
}

// Run this collector only in the environment that can reach the pipeline cluster.
// It writes locally and never transfers the bundle to another machine.
export async function writePreparedInputs(inputs, outputDirectory) {
  const bundle = { version: 1, preparedAt: new Date().toISOString(), inputs };
  validatePreparedInputs(bundle);
  const folder = resolve(outputDirectory);
  await mkdir(dirname(folder), { recursive: true, mode: 0o700 });
  try {
    await mkdir(folder, { mode: 0o700 });
  } catch {
    throw new SetupError('Cannot create the output directory. Choose a new, writable directory.');
  }
  const filename = join(folder, 'inputs.json');
  try {
    await writeFile(filename, JSON.stringify(bundle, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    return filename;
  } catch {
    await rm(folder, { recursive: true, force: true });
    throw new SetupError('Could not write prepared inputs.');
  }
}

export async function readPreparedInputs(filename) {
  let bundle;
  try {
    const info = await stat(filename);
    if (!info.isFile() || info.size > 8 * 1024 * 1024) {
      throw new SetupError('Prepared inputs must be a regular file of at most 8 MiB.');
    }
    if (process.platform !== 'win32' && (info.mode & 0o077)) {
      throw new SetupError('Prepared inputs contain credentials; restrict file permissions to 0600.');
    }
    bundle = JSON.parse(await readFile(filename, 'utf8'));
  } catch (error) {
    if (error instanceof SetupError) throw error;
    // JSON parse errors may contain credential values; never echo them.
    throw new SetupError('Cannot read the prepared-inputs JSON file.');
  }
  return { inputs: validatePreparedInputs(bundle), preparedAt: bundle.preparedAt };
}
