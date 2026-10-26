// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
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
      async edgeNodeId(page, clusterName) {
        calls.push({ method: 'edgeNodeId', clusterName });
        return 'cluster-123';
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
      async deleteEdgeNode(page, { clusterName }) {
        calls.push({ method: 'deleteEdgeNode', clusterName });
      },
    };

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3: 'put', file, key });
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

    // Verify exact sequence of steps 1-10
    const expectedMethods = [
      'edgeNodeState',
      'addEdgeNode',
      'downloadElmZip',
      { s3: 'put' },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { loadKubeconfig: true },
      'setUpCloudConnector',
      { fetchElm: dir },
      { elmInit: {} },
      'deployEic',
      'downloadEicZip',
      { s3: 'put' },
      { waitForTask: 'configure-mesh-eic' },
      'finishEicDeployment',
    ];

    for (let i = 0; i < expectedMethods.length; i++) {
      const expected = expectedMethods[i];
      const actual = calls[i];
      if (typeof expected === 'string') {
        assert.equal(actual.method, expected, `Step ${i + 1} should be ${expected}`);
      } else if (expected.s3) {
        assert.equal(actual.s3, expected.s3, `Step ${i + 1} should be S3 ${expected.s3}`);
      } else if (expected.waitForTask) {
        assert.equal(actual.waitForTask, expected.waitForTask, `Step ${i + 1} should wait for ${expected.waitForTask}`);
      } else if (expected.loadKubeconfig) {
        assert.ok(actual.loadKubeconfig, `Step ${i + 1} should load kubeconfig`);
      } else if (expected.fetchElm) {
        assert.ok(actual.fetchElm, `Step ${i + 1} should fetch elm`);
      } else if (expected.elmInit !== undefined) {
        assert.ok(actual.elmInit, `Step ${i + 1} should run elmInit`);
      }
    }

    // Verify uploads
    const uploads = calls.filter(c => c.s3 === 'put');
    assert.equal(uploads.length, 2);
    assert.ok(uploads[0].key.includes('elm/restricted-resources-elm.zip'));
    assert.ok(uploads[1].key.includes('edge-icell/restricted-resources-eic.zip'));
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
      async addEdgeNode(page, opts) {
        calls.push({ method: 'addEdgeNode' });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip' });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, opts) {
        calls.push({ method: 'setUpCloudConnector' });
        return join(dir, 'context.yaml');
      },
      async deployEic(page, opts) {
        calls.push({ method: 'deployEic' });
      },
      async downloadEicZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadEicZip' });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment(page, opts) {
        calls.push({ method: 'finishEicDeployment' });
      },
      async deleteEdgeNode(page, opts) {
        calls.push({ method: 'deleteEdgeNode' });
      },
    };

    const fakeS3 = { async put() { calls.push({ s3: 'put' }); } };

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
      waitForTask: async () => { calls.push({ waitForTask: true }); },
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => { calls.push({ elmInit: true }); },
      password: 'test-password',
      log: () => {},
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: no addEdgeNode, setUpCloudConnector, or elmInit
    assert.ok(!calls.some(c => c.method === 'addEdgeNode'), 'Should not call addEdgeNode');
    assert.ok(!calls.some(c => c.method === 'setUpCloudConnector'), 'Should not call setUpCloudConnector');
    assert.ok(!calls.some(c => c.elmInit), 'Should not call elmInit');

    // Verify: deployEic and both uploads still happen
    assert.ok(calls.some(c => c.method === 'deployEic'), 'Should call deployEic');
    assert.ok(calls.some(c => c.method === 'downloadElmZip'), 'Should call downloadElmZip');
    assert.ok(calls.some(c => c.method === 'downloadEicZip'), 'Should call downloadEicZip');
    const uploads = calls.filter(c => c.s3 === 'put');
    assert.equal(uploads.length, 2, 'Should upload both bundles');
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
      async downloadElmZip(page, { dir }) {
        calls.push({ method: 'downloadElmZip' });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async downloadEicZip(page, { dir }) {
        calls.push({ method: 'downloadEicZip' });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async deployEic() {
        calls.push({ method: 'deployEic' });
      },
      async finishEicDeployment() {
        calls.push({ method: 'finishEicDeployment' });
      },
    };

    const fakeS3 = { async put() { calls.push({ s3: 'put' }); } };

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
      waitForTask: async () => { calls.push({ waitForTask: true }); },
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
    // Verify: finishEicDeployment is still called
    assert.ok(calls.some(c => c.method === 'finishEicDeployment'), 'Should call finishEicDeployment');
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
      async addEdgeNode(page, { clusterName }) {
        calls.push({ method: 'addEdgeNode', clusterName });
      },
      async downloadElmZip(page, { dir }) {
        calls.push({ method: 'downloadElmZip' });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector() {
        calls.push({ method: 'setUpCloudConnector' });
        return join(dir, 'context.yaml');
      },
      async deployEic() {
        calls.push({ method: 'deployEic' });
      },
      async downloadEicZip(page, { dir }) {
        calls.push({ method: 'downloadEicZip' });
        return join(dir, 'restricted-resources-eic.zip');
      },
      async finishEicDeployment() {
        calls.push({ method: 'finishEicDeployment' });
      },
    };

    const fakeS3 = { async put() { calls.push({ s3: 'put' }); } };

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
      waitForTask: async () => {},
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
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

test('unknown_state_changes_nothing', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'unknown';
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
      (err) => err instanceof SetupError && err.message.includes('unknown state'),
      'Should reject with SetupError for unknown state'
    );

    // Verify: only edgeNodeState was called
    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, 'edgeNodeState');
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

test('kubeconfig_file_private', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'roks-flow-test-'));
  try {
    const fakeSteps = {
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) {
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { kubeconfigFile }) {
        // Record the file path so we can check it later
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
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
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
    const kubeconfigPath = join(dir, 'edgelm-kubeconfig.yaml');
    const stats = await stat(kubeconfigPath);
    const content = await readFile(kubeconfigPath, 'utf8');

    assert.equal(content, kubeconfigContent, 'Kubeconfig content should match');
    if (process.platform !== 'win32') {
      const mode = stats.mode & 0o777;
      assert.equal(mode, 0o600, 'Kubeconfig file should have mode 0600');
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
