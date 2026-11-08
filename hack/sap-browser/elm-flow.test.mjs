// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { SetupError } from './inputs.mjs';
import { runDeployFlow, runTeardownFlow } from './elm-flow.mjs';

// Helper to create fake steps with default session methods
function makeFakeSteps(overrides = {}) {
  return {
    async isSessionExpired() { return false; },
    async openEdgeNode() {},
    async edgeNodeElmId() { return '12345'; },
    ...overrides,
  };
}

test('fresh_run_order', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: {
        solution: 'Edge Integration Cell',
        version: '1.0.0',
        namespaces: {
          main: 'edge-icell',
          secrets: 'edge-icell-secrets',
          ela: 'edge-icell-ela',
          services: 'edge-icell-services',
          gateways: 'istio-gateways',
        },
        virtualHost: 'eic.example.com',
        keyAlias: 'eic-key',
        sharedFsStorageClass: 'nfs-rwx',
        servicesDeployment: 'pr-123-eic-services',
        gatewaysDeployment: 'pr-123-eic-gateways',
      },
      services: ['redis', 'postgres'],
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'absent';
      },
      async addEdgeNode(page, { clusterName, registry, highAvailability }) {
        calls.push({ method: 'addEdgeNode', clusterName, registry, highAvailability });
      },
      async edgeNodeElmId() {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
        calls.push({ method: 'setUpCloudConnector', clusterName, kubeconfigFile, password, dir });
        return join(dir, 'context.yaml');
      },
      async deployEic(page, { clusterName, cell }) {
        calls.push({ method: 'deployEic', clusterName, cell });
      },
      async downloadEicZip(page, { clusterName, deployment, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, deployment, dir });
        return join(dir, `restricted-resources-${deployment}.zip`);
      },
      async resumeEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'resumeEicDeployment', clusterName, deployment });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
    });

    const fakeIsSteps = {
      async deployKeystore(page, { runtimes }) {
        calls.push({ isMethod: 'deployKeystore', runtimes });
      },
      async runtimeReady(page, { deployment }) {
        calls.push({ isMethod: 'runtimeReady', deployment });
        return true;
      },
      async deployArtifact(page, { pkg, artifact, deployment }) {
        calls.push({ isMethod: 'deployArtifact', pkg, artifact, deployment });
      },
      async artifactStates(page, { deployment }) {
        calls.push({ isMethod: 'artifactStates', deployment });
        return {
          ipfilterAPI: 'Started',
          testAPI: 'Started',
          Arp_https: 'Started',
          SLV_FLOW_ELSTER: 'Started',
        };
      },
    };

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3put: { file, key } });
      },
    };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'registry.example.com', namespace: 'ns', username: 'user', password: 'pass' },
      highAvailability: false,
      proxy: null,
    };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => {
        calls.push({ loadCells: true });
        return [cell];
      },
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async (pipelineTaskName) => {
        calls.push({ waitForTask: pipelineTaskName });
      },
      meshTask: 'configure-mesh-eic',
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
      recordNode: async (record) => {
        calls.push({ recordNode: record });
      },
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return null;
      },
      waitForLogin: async () => {
        calls.push({ waitForLogin: true });
      },
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify the flow followed the correct order
    assert.ok(calls.some(c => c.method === 'edgeNodeState'));
    assert.ok(calls.some(c => c.method === 'addEdgeNode'));
    assert.ok(calls.some(c => c.recordNode));
    assert.ok(calls.some(c => c.method === 'deployEic'));
    assert.ok(calls.some(c => c.method === 'resumeEicDeployment'));
    assert.ok(calls.some(c => c.isMethod === 'deployKeystore'));
    assert.ok(calls.some(c => c.isMethod === 'deployArtifact'));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_deletes', async () => {
  const calls = [];

  const fakeSteps = {
    async edgeNodeState() {
      calls.push({ method: 'edgeNodeState' });
      return 'initialized';
    },
    async removeEdgeNode(page, { clusterName }) {
      calls.push({ method: 'removeEdgeNode', clusterName });
    },
  };

  const result = await runTeardownFlow({
    page: {},
    steps: fakeSteps,
    clusterName: 'test-cluster',
    log: () => {},
  });

  assert.equal(result, 'edge-node-deleted');
  assert.ok(calls.some(c => c.method === 'removeEdgeNode'));
  assert.equal(calls.find(c => c.method === 'removeEdgeNode').clusterName, 'test-cluster');
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

  assert.deepEqual(calls, ['edgeNodeState']);
});

test('cell_without_eic_hands_over', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: null,
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
    });

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err instanceof SetupError && err.message.includes('EIC form values') && err.message.includes('edge-icell') && err.message.includes('not mapped'),
      'Should throw SetupError when cell has no eic property'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('proxy_run_hands_over_before_add', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
    });

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: { host: 'proxy.example.com', port: 8080 } },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [],
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err instanceof SetupError && err.message.includes('HTTP proxy') && err.message.includes('add the Edge Node by hand'),
      'Should throw SetupError when proxy is configured and node is absent'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('node_recorded_after_add', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'absent';
      },
      async addEdgeNode() {
        calls.push({ method: 'addEdgeNode' });
      },
      async edgeNodeElmId() {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async (record) => {
        calls.push({ recordNode: record });
      },
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    await runDeployFlow(ctx);

    // Verify recordNode was called after addEdgeNode and edgeNodeElmId
    const addIndex = calls.findIndex(c => c.method === 'addEdgeNode');
    const elmIdIndex = calls.findIndex(c => c.method === 'edgeNodeElmId');
    const recordIndex = calls.findIndex(c => c.recordNode);

    assert.ok(addIndex >= 0);
    assert.ok(elmIdIndex >= 0);
    assert.ok(recordIndex >= 0);
    assert.ok(addIndex < elmIdIndex);
    assert.ok(elmIdIndex < recordIndex);

    // Verify the record contains the correct values
    const recordCall = calls.find(c => c.recordNode);
    assert.equal(recordCall.recordNode.name, 'test-cluster');
    assert.equal(recordCall.recordNode.elmId, '12345');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('hcp_policy_hands_over_unproven_node', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'added';
      },
      async edgeNodeElmId() {
        calls.push({ method: 'edgeNodeElmId' });
        return '99999';
      },
    });

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'hand-over',
      loadCells: async () => [],
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return { name: 'test-cluster', elmId: '88888' };
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err instanceof SetupError && err.message.includes('exists'),
      'Should throw SetupError when leftoverPolicy is hand-over and existing node does not match record'
    );

    // Verify readNodeRecord and edgeNodeElmId were called
    assert.ok(calls.some(c => c.readNodeRecord));
    assert.ok(calls.some(c => c.method === 'edgeNodeElmId'));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('two_cells_order', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell1 = {
      component: 'edge-icell-1',
      deployment: 'pr-123-eic-1',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell-1', secrets: 'edge-icell-secrets-1', ela: 'edge-icell-ela-1', services: 'edge-icell-services-1', gateways: 'istio-gateways-1' }, virtualHost: 'eic-1.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-1-services', gatewaysDeployment: 'pr-123-eic-1-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const cell2 = {
      component: 'edge-icell-2',
      deployment: 'pr-123-eic-2',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell-2', secrets: 'edge-icell-secrets-2', ela: 'edge-icell-ela-2', services: 'edge-icell-services-2', gateways: 'istio-gateways-2' }, virtualHost: 'eic-2.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-2-services', gatewaysDeployment: 'pr-123-eic-2-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic(page, { cell }) {
        calls.push({ method: 'deployEic', deployment: cell.deployment });
      },
      async downloadEicZip(page, { deployment, dir }) {
        calls.push({ method: 'downloadEicZip', deployment });
        return join(dir, `restricted-resources-${deployment}.zip`);
      },
      async resumeEicDeployment(page, { deployment }) {
        calls.push({ method: 'resumeEicDeployment', deployment });
      },
      async eicDeploymentStatus() {
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put(file, key) { calls.push({ s3put: { key } }); } };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell1, cell2],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async (pipelineTaskName) => { calls.push({ waitForTask: pipelineTaskName }); },
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify both deployments happened in order
    const deployEicCalls = calls.filter(c => c.method === 'deployEic');
    assert.equal(deployEicCalls.length, 2);
    assert.equal(deployEicCalls[0].deployment, 'pr-123-eic-1');
    assert.equal(deployEicCalls[1].deployment, 'pr-123-eic-2');

    // Verify both zips were uploaded with correct components
    const s3Calls = calls.filter(c => c.s3put);
    assert.ok(s3Calls.some(c => c.s3put.key === 'test-prefix/edge-icell-1/restricted-resources-pr-123-eic-1.zip'));
    assert.ok(s3Calls.some(c => c.s3put.key === 'test-prefix/edge-icell-2/restricted-resources-pr-123-eic-2.zip'));

    // Verify mesh wait happened before resume
    const meshWaitIdx = calls.findIndex(c => c.waitForTask === 'configure-mesh-eic');
    const resume1Idx = calls.findIndex(c => c.method === 'resumeEicDeployment' && c.deployment === 'pr-123-eic-1');
    const resume2Idx = calls.findIndex(c => c.method === 'resumeEicDeployment' && c.deployment === 'pr-123-eic-2');
    assert.ok(meshWaitIdx < resume1Idx);
    assert.ok(meshWaitIdx < resume2Idx);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('waits_until_all_successful', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    let statusCallCount = 0;
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        statusCallCount++;
        if (statusCallCount < 3) {
          return { operation: 'In Progress', status: 'Deploying', version: '1.0.0' };
        }
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 500,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');
    assert.ok(statusCallCount >= 3, 'Should have polled status at least 3 times');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('status_timeout_hands_over', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        return { operation: 'In Progress', status: 'Deploying', version: '1.0.0' };
      },
    });

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 50,
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err instanceof SetupError && err.message.includes('pr-123-eic'),
      'Should throw SetupError when status polling times out'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('expired_session_relogin_and_retry', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    let deployEicCallCount = 0;
    let sessionExpiredCount = 0;

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {
        deployEicCallCount++;
        calls.push({ method: 'deployEic', callCount: deployEicCallCount });
        if (deployEicCallCount === 1) {
          const error = new Error('Session expired');
          error.name = 'SessionExpiredError';
          throw error;
        }
      },
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async isSessionExpired() {
        sessionExpiredCount++;
        calls.push({ method: 'isSessionExpired', callCount: sessionExpiredCount });
        return sessionExpiredCount === 1;
      },
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {
        calls.push({ waitForLogin: true });
      },
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify deployEic was called twice
    assert.equal(deployEicCallCount, 2);

    // Verify waitForLogin was called once
    const waitForLoginCalls = calls.filter(c => c.waitForLogin);
    assert.equal(waitForLoginCalls.length, 1);

    // Verify isSessionExpired was called
    assert.ok(sessionExpiredCount >= 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('other_error_not_retried', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    let deployEicCallCount = 0;

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {
        deployEicCallCount++;
        calls.push({ method: 'deployEic', callCount: deployEicCallCount });
        throw new Error('Some other error');
      },
      async isSessionExpired() {
        calls.push({ method: 'isSessionExpired' });
        return false;
      },
    });

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {
        calls.push({ waitForLogin: true });
      },
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    await assert.rejects(
      async () => await runDeployFlow(ctx),
      (err) => err.message === 'Some other error',
      'Should propagate non-session errors without retry'
    );

    // Verify deployEic was called only once
    assert.equal(deployEicCallCount, 1);

    // Verify waitForLogin was not called
    const waitForLoginCalls = calls.filter(c => c.waitForLogin);
    assert.equal(waitForLoginCalls.length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('integration_deploys_keystore_then_artifacts_per_cell', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell1 = {
      component: 'edge-icell-1',
      deployment: 'pr-123-eic-1',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell-1', secrets: 'edge-icell-secrets-1', ela: 'edge-icell-ela-1', services: 'edge-icell-services-1', gateways: 'istio-gateways-1' }, virtualHost: 'eic-1.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-1-services', gatewaysDeployment: 'pr-123-eic-1-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const cell2 = {
      component: 'edge-icell-2',
      deployment: 'pr-123-eic-2',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell-2', secrets: 'edge-icell-secrets-2', ela: 'edge-icell-ela-2', services: 'edge-icell-services-2', gateways: 'istio-gateways-2' }, virtualHost: 'eic-2.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-2-services', gatewaysDeployment: 'pr-123-eic-2-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
    });

    const fakeIsSteps = {
      async deployKeystore(page, { runtimes }) {
        calls.push({ isMethod: 'deployKeystore', runtimes });
      },
      async runtimeReady(page, { deployment }) {
        calls.push({ isMethod: 'runtimeReady', deployment });
        return true;
      },
      async deployArtifact(page, { pkg, artifact, deployment }) {
        calls.push({ isMethod: 'deployArtifact', pkg, artifact, deployment });
      },
      async artifactStates(page, { deployment }) {
        calls.push({ isMethod: 'artifactStates', deployment });
        return {
          ipfilterAPI: 'Started',
          testAPI: 'Started',
          Arp_https: 'Started',
          SLV_FLOW_ELSTER: 'Started',
        };
      },
    };

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell1, cell2],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    await runDeployFlow(ctx);

    // Verify deployKeystore was called once with both runtimes
    const keystoreCalls = calls.filter(c => c.isMethod === 'deployKeystore');
    assert.equal(keystoreCalls.length, 1);
    assert.deepEqual(keystoreCalls[0].runtimes, ['pr-123-eic-1', 'pr-123-eic-2']);

    // Verify keystore was deployed before any artifacts
    const keystoreIdx = calls.findIndex(c => c.isMethod === 'deployKeystore');
    const firstArtifactIdx = calls.findIndex(c => c.isMethod === 'deployArtifact');
    assert.ok(keystoreIdx < firstArtifactIdx);

    // Verify artifacts were deployed for both cells (4 artifacts each = 8 total)
    const artifactCalls = calls.filter(c => c.isMethod === 'deployArtifact');
    assert.equal(artifactCalls.length, 8);

    // Verify artifacts for cell1
    const cell1Artifacts = artifactCalls.filter(c => c.deployment === 'pr-123-eic-1');
    assert.equal(cell1Artifacts.length, 4);

    // Verify artifacts for cell2
    const cell2Artifacts = artifactCalls.filter(c => c.deployment === 'pr-123-eic-2');
    assert.equal(cell2Artifacts.length, 4);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('integration_waits_for_started', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    let artifactStatesCallCount = 0;

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        artifactStatesCallCount++;
        if (artifactStatesCallCount < 3) {
          return {
            ipfilterAPI: 'Starting',
            testAPI: 'Started',
            Arp_https: 'Starting',
            SLV_FLOW_ELSTER: 'Started',
          };
        }
        return {
          ipfilterAPI: 'Started',
          testAPI: 'Started',
          Arp_https: 'Started',
          SLV_FLOW_ELSTER: 'Started',
        };
      },
    };

    const fakeS3 = { async put() {} };

    const ctx = {
      page: {},
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => {},
      password: 'test-password',
      recordNode: async () => {},
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 500,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');
    assert.ok(artifactStatesCallCount >= 3);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
