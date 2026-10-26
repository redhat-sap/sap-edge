// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { SetupError } from './inputs.mjs';
import { elmPages } from './elm-pages.mjs';
import { runDeployFlow, runTeardownFlow } from './roks-flow.mjs';

test('fresh_run_order', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'absent';
      },
      async addEdgeNode(page, { clusterName, registry }) {
        calls.push({ method: 'addEdgeNode', clusterName, registry });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
        calls.push({ method: 'setUpCloudConnector', clusterName, kubeconfigFile, password, dir });
        return join(dir, 'context.yaml');
      },
      async deployEic(page, { clusterName, inputs, files }) {
        calls.push({ method: 'deployEic', clusterName, inputs, files });
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, dir });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, { clusterName }) {
        calls.push({ method: 'finishEicDeployment', clusterName });
      },
    };

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3put: { file, key } });
      },
    };

    const inputs = {
      clusterName: 'test-cluster',
      pipelineRun: 'test-run',
      postgres: { host: 'pg.example.com', port: '5432', database: 'db', username: 'user', password: 'pass' },
      redis: { host: 'redis.example.com', port: '6379', username: 'user', password: 'pass' },
      registry: { server: 'registry.example.com', namespace: 'ns', username: 'user', password: 'pass' },
      attachments: { postgresCA: 'postgres-ca-content', redisCA: 'redis-ca-content' },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: '',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async (pipelineTaskName) => {
        calls.push({ waitForTask: pipelineTaskName });
      },
      loadKubeconfig: async () => {
        calls.push({ loadKubeconfig: true });
        return 'kubeconfig-content';
      },
      fetchElm: async (dir) => {
        calls.push({ fetchElm: dir });
        return join(dir, 'elm');
      },
      elmInit: async (opts) => {
        calls.push({ elmInit: opts });
      },
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify exact ordered call log with full arguments
    const expected = [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'addEdgeNode', clusterName: 'test-cluster', registry: inputs.registry },
      { method: 'downloadElmZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-elm.zip'), key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { loadKubeconfig: true },
      { method: 'setUpCloudConnector', clusterName: 'test-cluster', kubeconfigFile: join(dir, 'edgelm-kubeconfig.yaml'), password: 'test-password', dir },
      { fetchElm: dir },
      { elmInit: { elmPath: join(dir, 'elm'), contextFile: join(dir, 'context.yaml'), password: 'test-password', cwd: dir } },
      { method: 'deployEic', clusterName: 'test-cluster', inputs, files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') } },
      { method: 'downloadEicZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-eic.zip'), key: 'test-prefix/edge-icell/restricted-resources-eic.zip' } },
      { waitForTask: 'configure-mesh-eic' },
      { method: 'finishEicDeployment', clusterName: 'test-cluster' },
    ];

    assert.deepEqual(calls, expected);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('resume_initialized_skips_sap_changes', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeId(page, clusterName) {
        calls.push({ method: 'edgeNodeId', clusterName });
        return 'cluster-123';
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async deployEic(page, { clusterName, inputs, files }) {
        calls.push({ method: 'deployEic', clusterName, inputs, files });
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, dir });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, { clusterName }) {
        calls.push({ method: 'finishEicDeployment', clusterName });
      },
    };

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3put: { file, key } });
      },
    };

    const inputs = {
      clusterName: 'test-cluster',
      postgres: { host: 'pg.example.com', port: '5432', database: 'db', username: 'user', password: 'pass' },
      redis: { host: 'redis.example.com', port: '6379', username: 'user', password: 'pass' },
      registry: { server: 'registry.example.com', namespace: 'ns', username: 'user', password: 'pass' },
      attachments: { postgresCA: 'postgres-ca-content', redisCA: 'redis-ca-content' },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: 'cluster-123',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async (pipelineTaskName) => {
        calls.push({ waitForTask: pipelineTaskName });
      },
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async (opts) => {
        calls.push({ elmInit: opts });
      },
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: no addEdgeNode, setUpCloudConnector, or elmInit
    assert.ok(!calls.some(c => c.method === 'addEdgeNode'), 'Should not call addEdgeNode');
    assert.ok(!calls.some(c => c.method === 'setUpCloudConnector'), 'Should not call setUpCloudConnector');
    assert.ok(!calls.some(c => c.elmInit), 'Should not call elmInit');

    // Verify exact ordered call log
    const expected = [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'edgeNodeId', clusterName: 'test-cluster' },
      { method: 'downloadElmZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-elm.zip'), key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { method: 'deployEic', clusterName: 'test-cluster', inputs, files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') } },
      { method: 'downloadEicZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-eic.zip'), key: 'test-prefix/edge-icell/restricted-resources-eic.zip' } },
      { waitForTask: 'configure-mesh-eic' },
      { method: 'finishEicDeployment', clusterName: 'test-cluster' },
    ];

    assert.deepEqual(calls, expected);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('resume_eic_deployed_skips_deploy', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'eic-deployed';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'cluster-123';
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, dir });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, { clusterName }) {
        calls.push({ method: 'finishEicDeployment', clusterName });
      },
    };

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3put: { file, key } });
      },
    };

    const inputs = {
      clusterName: 'test-cluster',
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: 'cluster-123',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async (pipelineTaskName) => {
        calls.push({ waitForTask: pipelineTaskName });
      },
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: deployEic is not called
    assert.ok(!calls.some(c => c.method === 'deployEic'), 'Should not call deployEic');

    // Verify exact ordered call log (both downloads/uploads and both waits still happen)
    const expected = [
      { method: 'edgeNodeState' },
      { method: 'edgeNodeId' },
      { method: 'downloadElmZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-elm.zip'), key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { method: 'downloadEicZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-eic.zip'), key: 'test-prefix/edge-icell/restricted-resources-eic.zip' } },
      { waitForTask: 'configure-mesh-eic' },
      { method: 'finishEicDeployment', clusterName: 'test-cluster' },
    ];

    assert.deepEqual(calls, expected);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('leftover_node_is_recreated', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'added';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'old-cluster-456';
      },
      async deleteEdgeNode(page, { clusterName }) {
        calls.push({ method: 'deleteEdgeNode', clusterName });
      },
      async addEdgeNode(page, { clusterName, registry }) {
        calls.push({ method: 'addEdgeNode', clusterName, registry });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
        calls.push({ method: 'setUpCloudConnector', clusterName, kubeconfigFile, password, dir });
        return join(dir, 'context.yaml');
      },
      async deployEic(page, { clusterName, inputs, files }) {
        calls.push({ method: 'deployEic', clusterName, inputs, files });
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, dir });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, { clusterName }) {
        calls.push({ method: 'finishEicDeployment', clusterName });
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'reg', namespace: 'ns', username: 'u', password: 'p' },
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: 'cluster-123',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => { calls.push({ waitForTask: true }); },
      loadKubeconfig: async () => { calls.push({ loadKubeconfig: true }); return 'kubeconfig'; },
      fetchElm: async () => { calls.push({ fetchElm: true }); return join(dir, 'elm'); },
      elmInit: async () => { calls.push({ elmInit: true }); },
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: deleteEdgeNode is called before addEdgeNode
    const deleteIndex = calls.findIndex(c => c.method === 'deleteEdgeNode');
    const addIndex = calls.findIndex(c => c.method === 'addEdgeNode');
    assert.ok(deleteIndex >= 0, 'Should call deleteEdgeNode');
    assert.ok(addIndex >= 0, 'Should call addEdgeNode');
    assert.ok(deleteIndex < addIndex, 'deleteEdgeNode should be called before addEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('unknown_cluster_id_never_deletes', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'added';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'some-cluster-id';
      },
      async deleteEdgeNode() {
        calls.push({ method: 'deleteEdgeNode' });
      },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      clusterEdgeNodeId: 'unknown',
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      log: () => {},
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err instanceof SetupError && err.message.includes('Cannot verify') && err.message.includes('not deleting'),
      'Should reject with SetupError when cluster ID is unknown and Edge Node exists'
    );

    // Verify: edgeNodeId was called but deleteEdgeNode was not
    assert.ok(calls.some(c => c.method === 'edgeNodeId'));
    assert.ok(!calls.some(c => c.method === 'deleteEdgeNode'), 'Should not call deleteEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('empty_cluster_id_recreates_existing_node', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'initialized';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return '';
      },
      async deleteEdgeNode(page, { clusterName }) {
        calls.push({ method: 'deleteEdgeNode', clusterName });
      },
      async addEdgeNode(page, { clusterName, registry }) {
        calls.push({ method: 'addEdgeNode', clusterName, registry });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
        calls.push({ method: 'setUpCloudConnector', clusterName, kubeconfigFile, password, dir });
        return join(dir, 'context.yaml');
      },
      async deployEic(page, { clusterName, inputs, files }) {
        calls.push({ method: 'deployEic', clusterName, inputs, files });
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, dir });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, { clusterName }) {
        calls.push({ method: 'finishEicDeployment', clusterName });
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'reg', namespace: 'ns', username: 'u', password: 'p' },
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: '',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => { calls.push({ waitForTask: true }); },
      loadKubeconfig: async () => { calls.push({ loadKubeconfig: true }); return 'kubeconfig'; },
      fetchElm: async () => { calls.push({ fetchElm: true }); return join(dir, 'elm'); },
      elmInit: async () => { calls.push({ elmInit: true }); },
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: deleteEdgeNode then addEdgeNode, then the full fresh path
    const methods = calls.map(c => c.method).filter(Boolean);
    assert.ok(methods.includes('deleteEdgeNode'), 'Should call deleteEdgeNode');
    assert.ok(methods.includes('addEdgeNode'), 'Should call addEdgeNode');
    assert.ok(methods.includes('setUpCloudConnector'), 'Should call setUpCloudConnector');
    assert.ok(methods.includes('deployEic'), 'Should call deployEic');

    const deleteIndex = methods.indexOf('deleteEdgeNode');
    const addIndex = methods.indexOf('addEdgeNode');
    assert.ok(deleteIndex < addIndex, 'deleteEdgeNode should be called before addEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('id_comparison_is_normalized', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'initialized';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return ' ABC-123 ';
      },
      async deleteEdgeNode() {
        calls.push({ method: 'deleteEdgeNode' });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async deployEic(page, { clusterName, inputs, files }) {
        calls.push({ method: 'deployEic', clusterName, inputs, files });
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, dir });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, { clusterName }) {
        calls.push({ method: 'finishEicDeployment', clusterName });
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const inputs = {
      clusterName: 'test-cluster',
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: 'abc-123',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => { calls.push({ waitForTask: true }); },
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: no delete/add (IDs match after normalization)
    assert.ok(!calls.some(c => c.method === 'deleteEdgeNode'), 'Should not call deleteEdgeNode');
    assert.ok(!calls.some(c => c.method === 'addEdgeNode'), 'Should not call addEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('deploy_rejects_unexpected_state', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push('edgeNodeState');
        return 'error';
      },
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      clusterEdgeNodeId: 'cluster-123',
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      log: () => {},
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err instanceof SetupError && err.message.includes('unrecognised state'),
      'Should reject with SetupError for unrecognised state'
    );

    // Verify: only edgeNodeState was called
    assert.deepEqual(calls, ['edgeNodeState']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_rejects_unexpected_state', async () => {
  const calls = [];

  const fakeSteps = {
    async edgeNodeState() {
      calls.push('edgeNodeState');
      return undefined;
    },
  };

  await assert.rejects(
    async () => await runTeardownFlow({
      page: {},
      steps: fakeSteps,
      clusterName: 'test-cluster',
      log: () => {},
    }),
    (err) => err instanceof SetupError && err.message.includes('unrecognised state'),
    'Should reject with SetupError for unrecognised state'
  );

  // Verify: only edgeNodeState was called
  assert.deepEqual(calls, ['edgeNodeState']);
});

test('kubeconfig_file_private', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    // Pre-create the kubeconfig file with wrong mode
    const kubeconfigPath = join(dir, 'edgelm-kubeconfig.yaml');
    await writeFile(kubeconfigPath, 'old-content', { mode: 0o644 });

    const fakeSteps = {
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) {
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector() {
        return join(dir, 'context.yaml');
      },
      async deployEic() {},
      async downloadEicZip(page, { dir }) {
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment() {},
    };

    const fakeS3 = { async put() {} };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'reg', namespace: 'ns', username: 'u', password: 'p' },
      attachments: { postgresCA: 'postgres-ca-content', redisCA: 'redis-ca-content' },
    };

    const kubeconfigContent = 'kubeconfig-test-content';

    const ctx = {
      page: {},
      steps: fakeSteps,
      inputs,
      clusterEdgeNodeId: '',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      loadKubeconfig: async () => kubeconfigContent,
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      log: () => {},
    };

    await runDeployFlow(ctx);

    // Verify the kubeconfig file was created with correct mode and content
    const kubeconfigStats = await stat(kubeconfigPath);
    const kubeconfigActual = await readFile(kubeconfigPath, 'utf8');
    assert.equal(kubeconfigActual, kubeconfigContent, 'Kubeconfig content should match');

    // Verify CA files
    const postgresCAPath = join(dir, 'postgres-ca.crt');
    const redisCAPath = join(dir, 'redis-ca.crt');
    const postgresCAStats = await stat(postgresCAPath);
    const redisCAStats = await stat(redisCAPath);
    const postgresCAActual = await readFile(postgresCAPath, 'utf8');
    const redisCAActual = await readFile(redisCAPath, 'utf8');

    assert.equal(postgresCAActual, 'postgres-ca-content', 'Postgres CA content should match');
    assert.equal(redisCAActual, 'redis-ca-content', 'Redis CA content should match');

    if (process.platform !== 'win32') {
      assert.equal(kubeconfigStats.mode & 0o777, 0o600, 'Kubeconfig file should have mode 0600');
      assert.equal(postgresCAStats.mode & 0o777, 0o600, 'Postgres CA file should have mode 0600');
      assert.equal(redisCAStats.mode & 0o777, 0o600, 'Redis CA file should have mode 0600');
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_absent', async () => {
  const calls = [];

  const fakeSteps = {
    async edgeNodeState() {
      calls.push({ method: 'edgeNodeState' });
      return 'absent';
    },
  };

  const result = await runTeardownFlow({
    page: {},
    steps: fakeSteps,
    clusterName: 'test-cluster',
    log: () => {},
  });

  assert.equal(result, 'nothing-to-delete');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'edgeNodeState');
});

test('teardown_deletes', async () => {
  const calls = [];

  const fakeSteps = {
    async edgeNodeState() {
      calls.push({ method: 'edgeNodeState' });
      return 'initialized';
    },
    async deleteEdgeNode(page, { clusterName }) {
      calls.push({ method: 'deleteEdgeNode', clusterName });
    },
  };

  const result = await runTeardownFlow({
    page: {},
    steps: fakeSteps,
    clusterName: 'test-cluster',
    log: () => {},
  });

  assert.equal(result, 'edge-node-deleted');
  assert.ok(calls.some(c => c.method === 'deleteEdgeNode'));
  assert.equal(calls.find(c => c.method === 'deleteEdgeNode').clusterName, 'test-cluster');
});

test('stubs_say_not_mapped', async () => {
  const methods = [
    'edgeNodeState',
    'edgeNodeId',
    'addEdgeNode',
    'downloadElmZip',
    'setUpCloudConnector',
    'deployEic',
    'downloadEicZip',
    'finishEicDeployment',
    'deleteEdgeNode',
  ];

  for (const method of methods) {
    await assert.rejects(
      async () => await elmPages[method]({}, {}),
      (err) => err instanceof SetupError &&
        err.message.includes('ELM screen step not mapped yet') &&
        err.message.includes(method) &&
        err.message.includes('sapBrowserMode inspect'),
      `Method ${method} should throw correct stub error`
    );
  }
});
