// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { decodeSecret, SetupError } from './inputs.mjs';

function parameter(run, name) {
  return run.spec?.params?.find((entry) => entry.name === name)?.value;
}

function required(data, key, context = '') {
  const value = data[key];
  if (typeof value !== 'string' || !value.trim() || value === 'N/A' || value.includes('N/A:')) {
    const suffix = context ? ` ${context}` : '';
    throw new SetupError(`Required credential field is missing or unavailable: ${key}${suffix}`);
  }
  return value;
}

export async function loadRoksInputs(read, pipelineRun, {
  expectedRunUID,
  expectedClusterName,
  postgresPassword,
} = {}) {
  if (!postgresPassword || typeof postgresPassword !== 'string' || !postgresPassword.trim()) {
    throw new SetupError('Postgres password is required.');
  }

  const run = await read('pipelinerun', pipelineRun);
  if (expectedRunUID && run.metadata?.uid !== expectedRunUID) {
    throw new SetupError('PipelineRun UID does not match this browser task.');
  }
  if (run.spec?.pipelineRef?.name !== 'roks-eic-full-test-pipeline') {
    throw new SetupError('This helper currently supports roks-eic-full-test-pipeline only.');
  }

  const clusterName = parameter(run, 'clusterName');
  if (typeof clusterName !== 'string' || !/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(clusterName)) {
    throw new SetupError('PipelineRun has no valid clusterName.');
  }
  if (expectedClusterName && clusterName !== expectedClusterName) {
    throw new SetupError('Cluster name does not match this browser task.');
  }

  // Validate required TaskRuns
  const validateTaskRef = run.status?.childReferences?.find((child) =>
    child.pipelineTaskName === 'validate-and-get-access' && child.kind === 'TaskRun');
  if (!validateTaskRef) {
    throw new SetupError('PipelineRun has not reached validate-and-get-access yet.');
  }

  const registryTaskRef = run.status?.childReferences?.find((child) =>
    child.pipelineTaskName === 'registry-access' && child.kind === 'TaskRun');
  if (!registryTaskRef) {
    throw new SetupError('PipelineRun has not reached registry-access yet.');
  }

  // Check both tasks succeeded
  for (const { name, pipelineTaskName } of [
    { name: validateTaskRef.name, pipelineTaskName: 'validate-and-get-access' },
    { name: registryTaskRef.name, pipelineTaskName: 'registry-access' },
  ]) {
    const task = await read('taskrun', name);
    const ownedByRun = task.metadata?.ownerReferences?.some((owner) => owner.uid === run.metadata?.uid);
    const succeeded = task.status?.conditions?.some((condition) =>
      condition.type === 'Succeeded' && condition.status === 'True');
    if (!ownedByRun || !succeeded) {
      throw new SetupError(`${pipelineTaskName} must succeed for this PipelineRun first.`);
    }
  }

  // Read credentials from Secrets
  const credentialsSecret = await read('secret', `eic-credentials-roks-${clusterName}`);
  const credentialsData = decodeSecret(credentialsSecret);

  const registrySecret = await read('secret', `eic-registry-roks-${clusterName}`);
  const registryData = decodeSecret(registrySecret);

  // Build result object - never include the admin kubeconfig
  const context = '(deployPostgres and deployRedis must be "true")';
  return {
    clusterName,
    pipelineRun,
    postgres: {
      host: required(credentialsData, 'postgres-host', context),
      port: required(credentialsData, 'postgres-port', context),
      database: required(credentialsData, 'postgres-database', context),
      username: required(credentialsData, 'postgres-username', context),
      password: postgresPassword,
    },
    redis: {
      host: required(credentialsData, 'redis-host', context),
      port: required(credentialsData, 'redis-port', context),
      username: required(credentialsData, 'redis-username', context),
      password: required(credentialsData, 'redis-password', context),
    },
    registry: {
      server: required(registryData, 'server'),
      namespace: required(registryData, 'namespace'),
      username: required(registryData, 'username'),
      password: required(registryData, 'password'),
    },
    attachments: {
      postgresCA: required(credentialsData, 'postgres-ca', context),
      redisCA: required(credentialsData, 'redis-ca', context),
    },
  };
}

export async function loadRestrictedKubeconfig(read, clusterName) {
  const secret = await read('secret', `edgelm-kubeconfig-generated-${clusterName}`);
  const data = decodeSecret(secret);
  return required(data, 'kubeconfig');
}
