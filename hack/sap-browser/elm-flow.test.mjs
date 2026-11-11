// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { SetupError } from './inputs.mjs';
import { runDeployFlow, runTeardownFlow, runUpgradeFlow } from './elm-flow.mjs';

// Helper to create fake steps with default session methods
function makeFakeSteps(overrides = {}) {
  return {
    async isSessionExpired() { return false; },
    async openEdgeNode() {},
    async edgeNodeElmId() { return '12345'; },
    ...overrides,
  };
}

// Helper to create fake page with standard methods
function makeFakePage(calls = []) {
  return {
    url() { return 'https://example.com#/clusters/123'; },
    async goto(url) { calls.push({ goto: url }); },
    async reload() { calls.push({ reload: true }); },
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
        namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' },
        virtualHost: 'eic.example.com',
        keyAlias: 'eic-key',
        sharedFsStorageClass: 'nfs-rwx',
        servicesDeployment: 'pr-123-eic-services',
        gatewaysDeployment: 'pr-123-eic-gateways',
      },
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
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        // First 3 calls return null (deploy check, zip check, resume check), then Successful for poll
        return callCount > 3 ? { operation: 'Successful', status: 'Ready', version: '1.0.0' } : null;
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
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
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

    const fakePage = {
      url() { return 'https://example.com/some/page'; },
      async goto(url) { calls.push({ goto: url }); },
      async reload() { calls.push({ reload: true }); },
    };

    const ctx = {
      page: fakePage,
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

    // Verify exact ordered call log
    const expected = [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'addEdgeNode', clusterName: 'test-cluster', registry: inputs.registry, highAvailability: false },
      { method: 'edgeNodeElmId' },
      { recordNode: { name: 'test-cluster', elmId: '12345' } },
      { method: 'downloadElmZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-elm.zip'), key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { loadKubeconfig: true },
      { method: 'setUpCloudConnector', clusterName: 'test-cluster', kubeconfigFile: join(dir, 'edgelm-kubeconfig.yaml'), password: 'test-password', dir },
      { fetchElm: dir },
      { elmInit: { elmPath: join(dir, 'elm'), contextFile: join(dir, 'context.yaml'), password: 'test-password', cwd: dir, log: ctx.log } },
      { loadCells: true },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { method: 'deployEic', clusterName: 'test-cluster', cell },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { method: 'downloadEicZip', clusterName: 'test-cluster', deployment: 'pr-123-eic', dir },
      { s3put: { file: join(dir, 'restricted-resources-pr-123-eic.zip'), key: 'test-prefix/edge-icell/restricted-resources-pr-123-eic.zip' } },
      { waitForTask: 'configure-mesh-eic' },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { method: 'resumeEicDeployment', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { reload: true },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { goto: 'https://example.com/shell/home' },
      { isMethod: 'deployKeystore', runtimes: ['pr-123-eic'] },
      { isMethod: 'runtimeReady', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'APIMUsecases', artifact: 'ipfilterAPI', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'APIMUsecases', artifact: 'testAPI', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'Arpith_Test', artifact: 'Arp_https', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'SLV_TEST_FLOW_ELSTER', artifact: 'SLV_FLOW_ELSTER', deployment: 'pr-123-eic' },
      { isMethod: 'artifactStates', deployment: 'pr-123-eic' },
    ];

    assert.deepEqual(calls, expected);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('resume_initialized_skips_sap_changes', async () => {
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
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        return callCount <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
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
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const fakeIsSteps = {
      async deployKeystore(page, { runtimes }) { calls.push({ isMethod: 'deployKeystore', runtimes }); },
      async runtimeReady(page, { deployment }) { calls.push({ isMethod: 'runtimeReady', deployment }); return true; },
      async deployArtifact(page, { pkg, artifact, deployment }) { calls.push({ isMethod: 'deployArtifact', pkg, artifact, deployment }); },
      async artifactStates(page, { deployment }) {
        calls.push({ isMethod: 'artifactStates', deployment });
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put(file, key) { calls.push({ s3put: { file, key } }); } };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'registry.example.com', namespace: 'ns', username: 'user', password: 'pass' },
      highAvailability: false,
      proxy: null,
    };

    const fakePage = {
      url() { return 'https://example.com/some/page'; },
      async goto(url) { calls.push({ goto: url }); },
      async reload() { calls.push({ reload: true }); },
    };

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: 'cluster-123',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
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

    // Verify exact ordered call log
    const expected = [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'edgeNodeId', clusterName: 'test-cluster' },
      { method: 'downloadElmZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-elm.zip'), key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { method: 'deployEic', clusterName: 'test-cluster', cell },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { method: 'downloadEicZip', clusterName: 'test-cluster', deployment: 'pr-123-eic', dir },
      { s3put: { file: join(dir, 'restricted-resources-pr-123-eic.zip'), key: 'test-prefix/edge-icell/restricted-resources-pr-123-eic.zip' } },
      { waitForTask: 'configure-mesh-eic' },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { method: 'resumeEicDeployment', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { reload: true },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { goto: 'https://example.com/shell/home' },
      { isMethod: 'deployKeystore', runtimes: ['pr-123-eic'] },
      { isMethod: 'runtimeReady', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'APIMUsecases', artifact: 'ipfilterAPI', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'APIMUsecases', artifact: 'testAPI', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'Arpith_Test', artifact: 'Arp_https', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'SLV_TEST_FLOW_ELSTER', artifact: 'SLV_FLOW_ELSTER', deployment: 'pr-123-eic' },
      { isMethod: 'artifactStates', deployment: 'pr-123-eic' },
    ];

    assert.deepEqual(calls, expected);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('resume_eic_deployed_skips_deploy', async () => {
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
        return 'initialized';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'cluster-123';
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        // Always return Successful (R5 form)
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
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
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const fakeIsSteps = {
      async deployKeystore(page, { runtimes }) { calls.push({ isMethod: 'deployKeystore', runtimes }); },
      async runtimeReady(page, { deployment }) { calls.push({ isMethod: 'runtimeReady', deployment }); return true; },
      async deployArtifact(page, { pkg, artifact, deployment }) { calls.push({ isMethod: 'deployArtifact', pkg, artifact, deployment }); },
      async artifactStates(page, { deployment }) {
        calls.push({ isMethod: 'artifactStates', deployment });
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put(file, key) { calls.push({ s3put: { file, key } }); } };

    const inputs = {
      clusterName: 'test-cluster',
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
      registry: {},
      highAvailability: false,
      proxy: null,
    };

    const fakePage = {
      url() { return 'https://example.com/some/page'; },
      async goto(url) { calls.push({ goto: url }); },
      async reload() { calls.push({ reload: true }); },
    };

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: 'cluster-123',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
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

    // Verify exact ordered call log (R5 Successful path: still runs ELM zip, upload, waits, status poll and integration flow)
    const expected = [
      { method: 'edgeNodeState' },
      { method: 'edgeNodeId' },
      { method: 'downloadElmZip', clusterName: 'test-cluster', dir },
      { s3put: { file: join(dir, 'restricted-resources-elm.zip'), key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      // No deployEic (status is Successful)
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      // No downloadEicZip or upload (status is Successful)
      { waitForTask: 'configure-mesh-eic' },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      // No resumeEicDeployment (status is Successful)
       { reload: true },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { goto: 'https://example.com/shell/home' },
      { isMethod: 'deployKeystore', runtimes: ['pr-123-eic'] },
      { isMethod: 'runtimeReady', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'APIMUsecases', artifact: 'ipfilterAPI', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'APIMUsecases', artifact: 'testAPI', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'Arpith_Test', artifact: 'Arp_https', deployment: 'pr-123-eic' },
      { isMethod: 'deployArtifact', pkg: 'SLV_TEST_FLOW_ELSTER', artifact: 'SLV_FLOW_ELSTER', deployment: 'pr-123-eic' },
      { isMethod: 'artifactStates', deployment: 'pr-123-eic' },
    ];

    assert.deepEqual(calls, expected);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('leftover_node_is_recreated', async () => {
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
        return 'added';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'old-cluster-456';
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async addEdgeNode(page, { clusterName, registry, highAvailability }) {
        calls.push({ method: 'addEdgeNode', clusterName, registry, highAvailability });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
        calls.push({ method: 'setUpCloudConnector', clusterName, kubeconfigFile, password, dir });
        return join(dir, 'context.yaml');
      },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        return callCount <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async openEdgeNode() {},
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'reg', namespace: 'ns', username: 'u', password: 'p' },
      highAvailability: false,
      proxy: null,
    };

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: 'cluster-123',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => { calls.push({ waitForTask: true }); },
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => { calls.push({ loadKubeconfig: true }); return 'kubeconfig'; },
      fetchElm: async () => { calls.push({ fetchElm: true }); return join(dir, 'elm'); },
      elmInit: async () => { calls.push({ elmInit: true }); },
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

    // Verify: removeEdgeNode is called before addEdgeNode
    const deleteIndex = calls.findIndex(c => c.method === 'removeEdgeNode');
    const addIndex = calls.findIndex(c => c.method === 'addEdgeNode');
    assert.ok(deleteIndex >= 0, 'Should call removeEdgeNode');
    assert.ok(addIndex >= 0, 'Should call addEdgeNode');
    assert.ok(deleteIndex < addIndex, 'removeEdgeNode should be called before addEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('unknown_cluster_id_never_deletes', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() {
        calls.push({ method: 'edgeNodeState' });
        return 'added';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'some-cluster-id';
      },
      async removeEdgeNode() {
        calls.push({ method: 'removeEdgeNode' });
      },
    });

    const ctx = {
      page: makeFakePage(calls),
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: 'unknown',
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
      (err) => err instanceof SetupError && err.message.includes('Cannot verify') && err.message.includes('not deleting'),
      'Should reject with SetupError when cluster ID is unknown and Edge Node exists'
    );

    // Verify: edgeNodeId was called but removeEdgeNode was not
    assert.ok(calls.some(c => c.method === 'edgeNodeId'));
    assert.ok(!calls.some(c => c.method === 'removeEdgeNode'), 'Should not call removeEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('empty_cluster_id_recreates_existing_node', async () => {
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
        return 'initialized';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return '';
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async addEdgeNode(page, { clusterName, registry, highAvailability }) {
        calls.push({ method: 'addEdgeNode', clusterName, registry, highAvailability });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
        calls.push({ method: 'setUpCloudConnector', clusterName, kubeconfigFile, password, dir });
        return join(dir, 'context.yaml');
      },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        return callCount <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deployEic() { calls.push({ method: 'deployEic' }); },
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async openEdgeNode() {},
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'reg', namespace: 'ns', username: 'u', password: 'p' },
      highAvailability: false,
      proxy: null,
    };

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => { calls.push({ waitForTask: true }); },
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => { calls.push({ loadKubeconfig: true }); return 'kubeconfig'; },
      fetchElm: async () => { calls.push({ fetchElm: true }); return join(dir, 'elm'); },
      elmInit: async () => { calls.push({ elmInit: true }); },
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

    // Verify: removeEdgeNode then addEdgeNode, then the full fresh path
    const methods = calls.map(c => c.method).filter(Boolean);
    assert.ok(methods.includes('removeEdgeNode'), 'Should call removeEdgeNode');
    assert.ok(methods.includes('addEdgeNode'), 'Should call addEdgeNode');
    assert.ok(methods.includes('setUpCloudConnector'), 'Should call setUpCloudConnector');
    assert.ok(methods.includes('deployEic'), 'Should call deployEic');

    const deleteIndex = methods.indexOf('removeEdgeNode');
    const addIndex = methods.indexOf('addEdgeNode');
    assert.ok(deleteIndex < addIndex, 'removeEdgeNode should be called before addEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('id_comparison_is_normalized', async () => {
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
        return 'initialized';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return ' ABC-123 ';
      },
      async removeEdgeNode() {
        calls.push({ method: 'removeEdgeNode' });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip', clusterName, dir });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        return callCount <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async openEdgeNode() {},
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const inputs = {
      clusterName: 'test-cluster',
      attachments: { postgresCA: 'pg-ca', redisCA: 'redis-ca' },
      registry: {},
      highAvailability: false,
      proxy: null,
    };

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: 'abc-123',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => { calls.push({ waitForTask: true }); },
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

    // Verify: no delete/add (IDs match after normalization)
    assert.ok(!calls.some(c => c.method === 'removeEdgeNode'), 'Should not call removeEdgeNode');
    assert.ok(!calls.some(c => c.method === 'addEdgeNode'), 'Should not call addEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('deploy_rejects_unexpected_state', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() {
        calls.push('edgeNodeState');
        return 'error';
      },
    });

    const ctx = {
      page: makeFakePage(calls),
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: 'cluster-123',
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
      (err) => err instanceof SetupError && err.message.includes('unrecognised state'),
      'Should reject with SetupError for unrecognised state'
    );

    // Verify: only edgeNodeState was called
    assert.deepEqual(calls, ['edgeNodeState']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('kubeconfig_file_private', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    // Pre-create the kubeconfig file with wrong mode
    const kubeconfigPath = join(dir, 'edgelm-kubeconfig.yaml');
    await writeFile(kubeconfigPath, 'old-content', { mode: 0o644 });

    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) {
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector() {
        return join(dir, 'context.yaml');
      },
      async eicDeploymentStatus() {
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deployEic() {},
      async downloadEicZip(page, { dir }) {
        return join(dir, 'restricted-resources-eic.zip');
      },
      async resumeEicDeployment() {},
      async openEdgeNode() {},
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

    const inputs = {
      clusterName: 'test-cluster',
      registry: { server: 'reg', namespace: 'ns', username: 'u', password: 'p' },
      highAvailability: false,
      proxy: null,
    };

    const kubeconfigContent = 'kubeconfig-test-content';

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => [cell],
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async () => {},
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => kubeconfigContent,
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

    // Verify the kubeconfig file was created with correct mode and content
    const kubeconfigStats = await stat(kubeconfigPath);
    const kubeconfigActual = await readFile(kubeconfigPath, 'utf8');
    assert.equal(kubeconfigActual, kubeconfigContent, 'Kubeconfig content should match');

    if (process.platform !== 'win32') {
      assert.equal(kubeconfigStats.mode & 0o777, 0o600, 'Kubeconfig file should have mode 0600');
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('unknown_leftover_policy_throws', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
    });

    const ctx = {
      page: makeFakePage(calls),
      steps: fakeSteps,
      isSteps: {},
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'unknown-policy',
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
      (err) => err instanceof SetupError && err.message.includes('Unknown leftoverPolicy'),
      'Should throw SetupError for unknown leftoverPolicy'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('handover_policy_matching_record_resumes', async () => {
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
        return 'initialized';
      },
      async edgeNodeElmId() {
        calls.push({ method: 'edgeNodeElmId' });
        return '88888';
      },
      async addEdgeNode() {
        calls.push({ method: 'addEdgeNode' });
      },
      async downloadElmZip(page, { clusterName, dir }) {
        calls.push({ method: 'downloadElmZip' });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        return callCount <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deployEic() { calls.push({ method: 'deployEic' }); },
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() { calls.push({ method: 'resumeEicDeployment' }); },
      async openEdgeNode() {},
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

    const inputs = {
      clusterName: 'test-cluster',
      registry: {},
      highAvailability: false,
      proxy: null,
    };

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs,
      clusterEdgeNodeId: '',
      leftoverPolicy: 'hand-over',
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
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return { name: 'test-cluster', elmId: '88888' }; // Matches edgeNodeElmId
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: readNodeRecord and edgeNodeElmId were called
    assert.ok(calls.some(c => c.readNodeRecord));
    assert.ok(calls.some(c => c.method === 'edgeNodeElmId'));

    // Verify: addEdgeNode and recordNode were NOT called (node was resumed)
    assert.ok(!calls.some(c => c.method === 'addEdgeNode'), 'Should not call addEdgeNode when resuming');
    assert.ok(!calls.some(c => c.recordNode), 'Should not call recordNode when resuming');
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
      async downloadElmZip(page, { dir }) {
        calls.push({ method: 'downloadElmZip' });
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector() {
        calls.push({ method: 'setUpCloudConnector' });
        return join(dir, 'context.yaml');
      },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const statusCalls = calls.filter(c => c.method === 'eicDeploymentStatus' && c.deployment === deployment);
        // First 3 calls per cell return null (deploy check, zip check, resume check), poll calls return Successful
        return statusCalls.length <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
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
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const fakeIsSteps = {
      async deployKeystore(page, { runtimes }) {
        calls.push({ isMethod: 'deployKeystore', runtimes });
      },
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put(file, key) { calls.push({ s3put: { key } }); } };

    const fakePage = {
      url() { return 'https://example.com/some/page'; },
      async goto(url) { calls.push({ goto: url }); },
      async reload() { calls.push({ reload: true }); },
    };

    const ctx = {
      page: fakePage,
      steps: fakeSteps,
      isSteps: fakeIsSteps,
      inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
      clusterEdgeNodeId: '',
      leftoverPolicy: 'delete',
      loadCells: async () => {
        calls.push({ loadCells: true });
        return [cell1, cell2];
      },
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForTask: async (pipelineTaskName) => { calls.push({ waitForTask: pipelineTaskName }); },
      meshTask: 'configure-mesh-eic',
      loadKubeconfig: async () => 'kubeconfig',
      fetchElm: async () => join(dir, 'elm'),
      elmInit: async () => { calls.push({ elmInit: true }); },
      password: 'test-password',
      recordNode: async (record) => { calls.push({ recordNode: record }); },
      readNodeRecord: async () => null,
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify full ordered sequence with deepEqual
    const expected = [
      { method: 'edgeNodeState' },
      { method: 'addEdgeNode' },
      { method: 'edgeNodeElmId' },
      { recordNode: { name: 'test-cluster', elmId: '12345' } },
      { method: 'downloadElmZip' },
      { s3put: { key: 'test-prefix/elm/restricted-resources-elm.zip' } },
      { waitForTask: 'generate-sa-based-kubeconfig' },
      { method: 'setUpCloudConnector' },
      { elmInit: true },
      { loadCells: true },
      // Deploy cell 1 (status check → deploy)
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-1' },
      { method: 'deployEic', deployment: 'pr-123-eic-1' },
      // Deploy cell 2 (status check → deploy)
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-2' },
      { method: 'deployEic', deployment: 'pr-123-eic-2' },
      // Download/upload cell 1
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-1' },
      { method: 'downloadEicZip', deployment: 'pr-123-eic-1' },
      { s3put: { key: 'test-prefix/edge-icell-1/restricted-resources-pr-123-eic-1.zip' } },
      // Download/upload cell 2
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-2' },
      { method: 'downloadEicZip', deployment: 'pr-123-eic-2' },
      { s3put: { key: 'test-prefix/edge-icell-2/restricted-resources-pr-123-eic-2.zip' } },
      // Wait mesh
      { waitForTask: 'configure-mesh-eic' },
      // Resume cell 1
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-1' },
      { method: 'resumeEicDeployment', deployment: 'pr-123-eic-1' },
      // Resume cell 2
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-2' },
      { method: 'resumeEicDeployment', deployment: 'pr-123-eic-2' },
      // Status poll round 1
       { reload: true },
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-1' },
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-2' },
      // Integration Suite
      { goto: 'https://example.com/shell/home' },
      { isMethod: 'deployKeystore', runtimes: ['pr-123-eic-1', 'pr-123-eic-2'] },
    ];

    assert.deepEqual(calls, expected);
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
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        return callCount <= 3 ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
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
      async isSessionExpired() {
        sessionExpiredCount++;
        calls.push({ method: 'isSessionExpired', callCount: sessionExpiredCount });
        return sessionExpiredCount === 1;
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
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

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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

    // Verify deployEic was called twice (first call threw session expired, second succeeded)
    assert.equal(deployEicCallCount, 2);

    // Verify waitForLogin was called exactly once
    const waitForLoginCalls = calls.filter(c => c.waitForLogin);
    assert.equal(waitForLoginCalls.length, 1, 'waitForLogin should be called exactly once');

    // Verify retry reopen uses goto(captured URL) instead of openEdgeNode (after node opened)
    const waitForLoginIdx = calls.findIndex(c => c.waitForLogin);
    const gotoAfterWaitForLogin = calls.slice(waitForLoginIdx).filter(c => c.goto);
    assert.ok(gotoAfterWaitForLogin.length > 0, 'Should use goto for reopen after session expiry (node already opened)');
    const openEdgeNodeAfterWaitForLogin = calls.slice(waitForLoginIdx).filter(c => c.method === 'openEdgeNode');
    assert.equal(openEdgeNodeAfterWaitForLogin.length, 0, 'Should not use openEdgeNode for retry after node opened');

    // Verify isSessionExpired was called exactly once
    assert.equal(sessionExpiredCount, 1, 'isSessionExpired should be called exactly once');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});










test('cell_without_eic_hands_over', async () => {
  const calls = [];
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
      page: makeFakePage(calls),
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
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
    });

    const ctx = {
      page: makeFakePage(calls),
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

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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
      page: makeFakePage(calls),
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

test('waits_until_all_successful', async () => {
  const calls = [];
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
        if (statusCallCount < 5) {
          return { operation: 'Initial', status: 'Deploying', version: '1.0.0' };
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

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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
    assert.ok(statusCallCount >= 5, 'Should have polled status at least 5 times');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('status_timeout_hands_over', async () => {
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
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
      async downloadEicZip(page, { deployment, dir }) { return join(dir, `restricted-resources-${deployment}.zip`); },
      async resumeEicDeployment() {},
      async eicDeploymentStatus() {
        return { operation: 'Initial', status: 'Deploying', version: '1.0.0' };
      },
    });

    const fakeS3 = { async put() {} };

    const fakePage = makeFakePage(calls);

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const ctx = {
      page: fakePage,
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
      async eicDeploymentStatus() { return null; },
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

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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
  const calls = [];
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

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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

test('unknown_operation_hands_over', async () => {
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
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async eicDeploymentStatus(page, { deployment }) {
        // Return unknown operation
        return { operation: 'UnknownOperation', status: 'Unknown', version: '1.0.0' };
      },
    });

    const fakePage = makeFakePage(calls);

    const fakeS3 = { async put() {} };

    const ctx = {
      page: fakePage,
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
      (err) => err instanceof SetupError && err.message.includes('pr-123-eic') && err.message.includes('UnknownOperation'),
      'Should throw SetupError for unknown operation'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('initial_operation_skips_deploy_resumes', async () => {
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
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {},
      async downloadElmZip(page, { dir }) { return join(dir, 'restricted-resources-elm.zip'); },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        const callCount = calls.filter(c => c.method === 'eicDeploymentStatus').length;
        // First 3 calls return Initial, then Successful for poll
        return callCount <= 3 ? { operation: 'Initial', status: 'Deploying', version: '1.0.0' } : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deployEic() {
        calls.push({ method: 'deployEic' });
      },
      async downloadEicZip(page, { deployment, dir }) {
        calls.push({ method: 'downloadEicZip', deployment });
        return join(dir, `restricted-resources-${deployment}.zip`);
      },
      async resumeEicDeployment(page, { deployment }) {
        calls.push({ method: 'resumeEicDeployment', deployment });
      },
      async openEdgeNode() {},
    });

    const fakeIsSteps = {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    };

    const fakeS3 = { async put() { calls.push({ s3put: true }); } };

    const fakePage = makeFakePage(calls);

    const ctx = {
      page: fakePage,
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
      timeoutMs: 100,
    };

    const result = await runDeployFlow(ctx);
    assert.equal(result, 'deployed');

    // Verify: no deployEic (Initial/Prepared path), but zip + upload + resume happened
    assert.ok(!calls.some(c => c.method === 'deployEic'), 'Should not call deployEic for Initial operation');
    assert.ok(calls.some(c => c.method === 'downloadEicZip'), 'Should call downloadEicZip');
    assert.ok(calls.some(c => c.s3put), 'Should upload to S3');
    assert.ok(calls.some(c => c.method === 'resumeEicDeployment'), 'Should call resumeEicDeployment');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_deletes', async () => {
  const calls = [];

  const fakeSteps = makeFakeSteps({
    async edgeNodeState() {
      calls.push({ method: 'edgeNodeState' });
      return 'initialized';
    },
    async edgeNodeElmId() {
      calls.push({ method: 'edgeNodeElmId' });
      return '12345';
    },
    async removeEdgeNode(page, { clusterName }) {
      calls.push({ method: 'removeEdgeNode', clusterName });
    },
    async eicDeploymentStatus() {
      return null; // No cells
    },
    async openEdgeNode(page, clusterName) {
      calls.push({ method: 'openEdgeNode', clusterName });
    },
  });

  const result = await runTeardownFlow({
    page: makeFakePage(calls),
    steps: fakeSteps,
    inputs: { clusterName: 'test-cluster' },
    cells: [],
    readNodeRecord: async () => {
      calls.push({ readNodeRecord: true });
      return { name: 'test-cluster', elmId: '12345' };
    },
    waitForLogin: async () => {},
    log: () => {},
    pollMs: 10,
    timeoutMs: 100,
  });

  assert.equal(result, 'edge-node-deleted');
  assert.ok(calls.some(c => c.method === 'removeEdgeNode'));
  assert.equal(calls.find(c => c.method === 'removeEdgeNode').clusterName, 'test-cluster');
});

test('teardown_absent', async () => {
  const calls = [];

  const fakeSteps = makeFakeSteps({
    async edgeNodeState() {
      calls.push({ method: 'edgeNodeState' });
      return 'absent';
    },
    async openEdgeNode(page, clusterName) {
      calls.push({ method: 'openEdgeNode', clusterName });
    },
  });

  const result = await runTeardownFlow({
    page: makeFakePage(calls),
    steps: fakeSteps,
    inputs: { clusterName: 'test-cluster' },
    cells: [],
    readNodeRecord: async () => {
      calls.push({ readNodeRecord: true });
      return null;
    },
    waitForLogin: async () => {},
    log: () => {},
    pollMs: 10,
    timeoutMs: 100,
  });

  assert.equal(result, 'nothing-to-delete');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'edgeNodeState');
});

test('teardown_rejects_unexpected_state', async () => {
  const calls = [];

  const fakeSteps = makeFakeSteps({
    async edgeNodeState() {
      calls.push('edgeNodeState');
      return undefined;
    },
    async openEdgeNode() {
      calls.push('openEdgeNode');
    },
  });

  await assert.rejects(
    async () => await runTeardownFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [],
      readNodeRecord: async () => {
        calls.push('readNodeRecord');
        return null;
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    }),
    (err) => err instanceof SetupError && err.message.includes('unrecognised state'),
    'Should reject with SetupError for unrecognised state'
  );

  assert.deepEqual(calls, ['edgeNodeState']);
});

test('upgrade_empty_version_skips', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    const fakeSteps = makeFakeSteps({});

    const result = await runUpgradeFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell],
      version: '',
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForMarker: async () => {},
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });

    assert.equal(result, 'nothing-to-upgrade');
    assert.equal(calls.length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_without_resources_only_waits', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    const fakeSteps = makeFakeSteps({
      async upgradeEic(page, { clusterName, deployment, version }) {
        calls.push({ method: 'upgradeEic', clusterName, deployment, version });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        return { operation: 'Successful', status: 'Ready', version: '2.0.0' };
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const result = await runUpgradeFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell],
      version: '2.0.0',
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForMarker: async () => {},
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });

    assert.equal(result, 'upgraded');

    // Verify: upgradeEic called, then status polled until Successful at new version
    assert.ok(calls.some(c => c.method === 'upgradeEic'));
    assert.ok(calls.some(c => c.method === 'eicDeploymentStatus'));
    assert.ok(!calls.some(c => c.method === 'downloadEicZip'));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_with_resources_uploads_waits_marker_then_resumes', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    let statusCallCount = 0;
    const fakeSteps = makeFakeSteps({
      async upgradeEic(page, { clusterName, deployment, version }) {
        calls.push({ method: 'upgradeEic', clusterName, deployment, version });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        statusCallCount++;
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment, callCount: statusCallCount });
        // First call: Prepared, second call (after resume): Successful
        if (statusCallCount === 1) {
          return { operation: 'Prepared', status: 'Preparing', version: '1.0.0' };
        }
        return { operation: 'Successful', status: 'Ready', version: '2.0.0' };
      },
      async downloadEicZip(page, { clusterName, deployment, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, deployment, dir });
        return join(dir, 'restricted-resources-pr-123-eic.zip');
      },
      async resumeEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'resumeEicDeployment', clusterName, deployment });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3put: { file, key } });
      },
    };

    let markerWaited = false;
    const result = await runUpgradeFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell],
      version: '2.0.0',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForMarker: async (path) => {
        markerWaited = true;
        calls.push({ waitForMarker: path });
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });

    assert.equal(result, 'upgraded');

    // Verify sequence: openEdgeNode → upgradeEic → reload → status Prepared → download → upload → waitMarker → resume → reload → status Successful
    const expected = [
      { method: 'openEdgeNode', clusterName: 'test-cluster' },
      { method: 'upgradeEic', clusterName: 'test-cluster', deployment: 'pr-123-eic', version: '2.0.0' },
      { reload: true },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic', callCount: 1 },
      { method: 'downloadEicZip', clusterName: 'test-cluster', deployment: 'pr-123-eic', dir },
      { s3put: { file: join(dir, 'restricted-resources-pr-123-eic.zip'), key: 'test-prefix/edge-icell/restricted-resources-pr-123-eic.zip' } },
      { waitForMarker: 'test-prefix/.applied/restricted-resources-pr-123-eic.zip' },
      { method: 'resumeEicDeployment', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
      { reload: true },
      { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic', callCount: 2 },
    ];

    assert.deepEqual(calls, expected);
    assert.ok(markerWaited);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_deletes_cells_then_node', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell1 = {
      component: 'edge-icell-1',
      deployment: 'pr-123-eic-1',
    };
    const cell2 = {
      component: 'edge-icell-2',
      deployment: 'pr-123-eic-2',
    };

    let statusCallCount = 0;
    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeElmId(page) {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        statusCallCount++;
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment, callCount: statusCallCount });
        // First 2 calls (one per cell) return present, then null (gone) on poll
        return statusCallCount <= 2 ? { operation: 'Successful', status: 'Ready', version: '1.0.0' } : null;
      },
      async deleteEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'deleteEicDeployment', clusterName, deployment });
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const result = await runTeardownFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell1, cell2],
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return { name: 'test-cluster', elmId: '12345' };
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });

    assert.equal(result, 'edge-node-deleted');

    // Verify sequence: state check → elmId → record → delete cells → wait until gone → remove node
    const deleteCell1Idx = calls.findIndex(c => c.method === 'deleteEicDeployment' && c.deployment === 'pr-123-eic-1');
    const deleteCell2Idx = calls.findIndex(c => c.method === 'deleteEicDeployment' && c.deployment === 'pr-123-eic-2');
    const removeNodeIdx = calls.findIndex(c => c.method === 'removeEdgeNode');

    assert.ok(deleteCell1Idx >= 0);
    assert.ok(deleteCell2Idx >= 0);
    assert.ok(removeNodeIdx >= 0);
    assert.ok(deleteCell1Idx < removeNodeIdx);
    assert.ok(deleteCell2Idx < removeNodeIdx);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_without_record_hands_over', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeElmId(page) {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async deleteEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'deleteEicDeployment', clusterName, deployment });
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    await assert.rejects(
      async () => await runTeardownFlow({
        page: makeFakePage(calls),
        steps: fakeSteps,
        inputs: { clusterName: 'test-cluster' },
        cells: [cell],
        readNodeRecord: async () => {
          calls.push({ readNodeRecord: true });
          return null; // No record
        },
        waitForLogin: async () => {},
        log: () => {},
        pollMs: 10,
        timeoutMs: 100,
      }),
      (err) => err instanceof SetupError && err.message.includes('not created by this run') && err.message.includes('remove it by hand'),
      'Should throw SetupError when no record exists'
    );

    assert.ok(calls.some(c => c.readNodeRecord));
    assert.ok(!calls.some(c => c.method === 'deleteEicDeployment'), 'Should not call deleteEicDeployment');
    assert.ok(!calls.some(c => c.method === 'removeEdgeNode'), 'Should not call removeEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_other_elm_id_hands_over', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeElmId(page) {
        calls.push({ method: 'edgeNodeElmId' });
        return '99999'; // Different from record
      },
      async deleteEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'deleteEicDeployment', clusterName, deployment });
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    await assert.rejects(
      async () => await runTeardownFlow({
        page: makeFakePage(calls),
        steps: fakeSteps,
        inputs: { clusterName: 'test-cluster' },
        cells: [cell],
        readNodeRecord: async () => {
          calls.push({ readNodeRecord: true });
          return { name: 'test-cluster', elmId: '12345' };
        },
        waitForLogin: async () => {},
        log: () => {},
        pollMs: 10,
        timeoutMs: 100,
      }),
      (err) => err instanceof SetupError && err.message.includes('not created by this run') && err.message.includes('remove it by hand'),
      'Should throw SetupError when elmId does not match'
    );

    assert.ok(calls.some(c => c.readNodeRecord));
    assert.ok(calls.some(c => c.method === 'edgeNodeElmId'));
    assert.ok(!calls.some(c => c.method === 'deleteEicDeployment'), 'Should not call deleteEicDeployment');
    assert.ok(!calls.some(c => c.method === 'removeEdgeNode'), 'Should not call removeEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_absent_node_nothing_to_delete', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'absent';
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const result = await runTeardownFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [],
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return null;
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });

    assert.equal(result, 'nothing-to-delete');
    // Should not check record or elmId when node is absent
    assert.ok(!calls.some(c => c.readNodeRecord));
    assert.ok(!calls.some(c => c.method === 'edgeNodeElmId'));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_prepared_handled_while_waiting', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    let statusCallCount = 0;
    const fakeSteps = makeFakeSteps({
      async upgradeEic(page, { clusterName, deployment, version }) {
        calls.push({ method: 'upgradeEic', clusterName, deployment, version });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        statusCallCount++;
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment, callCount: statusCallCount });
        // Round 1: Successful@old, Round 2: Prepared, Round 3: Successful@new
        if (statusCallCount === 1) {
          return { operation: 'Successful', status: 'Running', version: '1.0.0' };
        } else if (statusCallCount === 2) {
          return { operation: 'Prepared', status: 'Preparing', version: '1.0.0' };
        } else {
          return { operation: 'Successful', status: 'Ready', version: '2.0.0' };
        }
      },
      async downloadEicZip(page, { clusterName, deployment, dir }) {
        calls.push({ method: 'downloadEicZip', clusterName, deployment, dir });
        return join(dir, 'restricted-resources-pr-123-eic.zip');
      },
      async resumeEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'resumeEicDeployment', clusterName, deployment });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const fakeS3 = {
      async put(file, key) {
        calls.push({ s3put: { file, key } });
      },
    };

    const result = await runUpgradeFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell],
      version: '2.0.0',
      s3: fakeS3,
      s3Prefix: 'test-prefix/',
      dir,
      waitForMarker: async (path) => {
        calls.push({ waitForMarker: path });
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 500,
    });

    assert.equal(result, 'upgraded');

    // Verify: upgradeEic → poll round 1 (Successful@old) → poll round 2 (Prepared) → download/upload/marker/resume → poll round 3 (Successful@new)
    const downloadCalls = calls.filter(c => c.method === 'downloadEicZip');
    const resumeCalls = calls.filter(c => c.method === 'resumeEicDeployment');
    assert.equal(downloadCalls.length, 1, 'Should download exactly once');
    assert.equal(resumeCalls.length, 1, 'Should resume exactly once');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_unknown_operation_while_waiting_hands_over', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    let statusCallCount = 0;
    const fakeSteps = makeFakeSteps({
      async upgradeEic(page, { clusterName, deployment, version }) {
        calls.push({ method: 'upgradeEic', clusterName, deployment, version });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        statusCallCount++;
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment, callCount: statusCallCount });
        // Round 1: Successful@old, Round 2: UnknownOp
        if (statusCallCount === 1) {
          return { operation: 'Successful', status: 'Running', version: '1.0.0' };
        } else {
          return { operation: 'UnknownOperation', status: 'Unknown', version: '1.0.0' };
        }
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    await assert.rejects(
      async () => await runUpgradeFlow({
        page: makeFakePage(calls),
        steps: fakeSteps,
        inputs: { clusterName: 'test-cluster' },
        cells: [cell],
        version: '2.0.0',
        s3: {},
        s3Prefix: 'test-prefix/',
        dir,
        waitForMarker: async () => {},
        waitForLogin: async () => {},
        log: () => {},
        pollMs: 10,
        timeoutMs: 500,
      }),
      (err) => err instanceof SetupError && err.message.includes('pr-123-eic') && err.message.includes('UnknownOperation'),
      'Should throw SetupError naming deployment and operation'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_skips_absent_cell', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeElmId(page) {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        return null; // Row is absent
      },
      async deleteEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'deleteEicDeployment', clusterName, deployment });
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const result = await runTeardownFlow({
      page: makeFakePage(calls),
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell],
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return { name: 'test-cluster', elmId: '12345' };
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });

    assert.equal(result, 'edge-node-deleted');
    // Verify: deleteEicDeployment was not called (row is absent), but removeEdgeNode was called
    assert.ok(!calls.some(c => c.method === 'deleteEicDeployment'), 'Should not call deleteEicDeployment for absent row');
    assert.ok(calls.some(c => c.method === 'removeEdgeNode'), 'Should call removeEdgeNode');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_waits_for_rows_to_disappear', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    let pollRound = 0;
    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeElmId(page) {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment, pollRound });
        // First call: check before delete (present)
        // Poll round 1: still present
        // Poll round 2: gone
        if (pollRound === 0) {
          return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
        } else if (pollRound === 1) {
          return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
        } else {
          return null;
        }
      },
      async deleteEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'deleteEicDeployment', clusterName, deployment });
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    const result = await runTeardownFlow({
      page: {
        url() { return 'https://example.com#/clusters/123'; },
        async goto(url) { calls.push({ goto: url }); },
        async reload() {
          calls.push({ reload: true });
          pollRound++;
        },
      },
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells: [cell],
      readNodeRecord: async () => {
        calls.push({ readNodeRecord: true });
        return { name: 'test-cluster', elmId: '12345' };
      },
      waitForLogin: async () => {},
      log: () => {},
      pollMs: 10,
      timeoutMs: 500,
    });

    assert.equal(result, 'edge-node-deleted');
    // Prove the wait: removeEdgeNode comes after the second reload/status round (finding 5)
    // Expected sequence: delete, reload, status(pollRound=1, present), reload, status(pollRound=2, gone), remove
    assert.deepEqual(
      calls.filter(c => c.method === 'deleteEicDeployment' || c.reload === true || (c.method === 'eicDeploymentStatus' && c.pollRound >= 1) || c.method === 'removeEdgeNode'),
      [
        { method: 'deleteEicDeployment', clusterName: 'test-cluster', deployment: 'pr-123-eic' },
        { reload: true },
        { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic', pollRound: 1 },
        { reload: true },
        { method: 'eicDeploymentStatus', clusterName: 'test-cluster', deployment: 'pr-123-eic', pollRound: 2 },
        { method: 'removeEdgeNode', clusterName: 'test-cluster' },
      ]
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_timeout_hands_over', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    const fakeSteps = makeFakeSteps({
      async upgradeEic(page, { clusterName, deployment, version }) {
        calls.push({ method: 'upgradeEic', clusterName, deployment, version });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        // Cell stays Successful at old version (1.0.0), never reaches target version (2.0.0)
        return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    await assert.rejects(
      async () => await runUpgradeFlow({
        page: makeFakePage(calls),
        steps: fakeSteps,
        inputs: { clusterName: 'test-cluster' },
        cells: [cell],
        version: '2.0.0',
        s3: {},
        s3Prefix: 'test-prefix/',
        dir,
        waitForMarker: async () => {},
        waitForLogin: async () => {},
        log: () => {},
        pollMs: 10,
        timeoutMs: 50,
      }),
      (err) => err instanceof SetupError && err.message.includes('pr-123-eic') && err.message.includes('EIC upgrade'),
      'Should throw SetupError when upgrade times out, naming the pending deployment'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_initial_while_waiting_hands_over', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
    };

    let statusCallCount = 0;
    const fakeSteps = makeFakeSteps({
      async upgradeEic(page, { clusterName, deployment, version }) {
        calls.push({ method: 'upgradeEic', clusterName, deployment, version });
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        statusCallCount++;
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment, callCount: statusCallCount });
        // First round: Successful at old version, second round: Initial (not allowed)
        if (statusCallCount === 1) {
          return { operation: 'Successful', status: 'Ready', version: '1.0.0' };
        } else {
          return { operation: 'Initial', status: 'Deploying', version: '1.0.0' };
        }
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    await assert.rejects(
      async () => await runUpgradeFlow({
        page: makeFakePage(calls),
        steps: fakeSteps,
        inputs: { clusterName: 'test-cluster' },
        cells: [cell],
        version: '2.0.0',
        s3: {},
        s3Prefix: 'test-prefix/',
        dir,
        waitForMarker: async () => {},
        waitForLogin: async () => {},
        log: () => {},
        pollMs: 10,
        timeoutMs: 500,
      }),
      (err) => err instanceof SetupError && err.message.includes('pr-123-eic') && err.message.includes('Initial'),
      'Should throw SetupError when cell has Initial while waiting, not timeout'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('teardown_timeout_names_only_pending_cells', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cellA = {
      component: 'edge-icell-a',
      deployment: 'pr-123-eic-a',
    };
    const cellB = {
      component: 'edge-icell-b',
      deployment: 'pr-123-eic-b',
    };

    const fakeSteps = makeFakeSteps({
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'initialized';
      },
      async edgeNodeElmId(page) {
        calls.push({ method: 'edgeNodeElmId' });
        return '12345';
      },
      async eicDeploymentStatus(page, { clusterName, deployment }) {
        calls.push({ method: 'eicDeploymentStatus', clusterName, deployment });
        // Cell A: gone (null), Cell B: still present
        return deployment === 'pr-123-eic-a' ? null : { operation: 'Successful', status: 'Ready', version: '1.0.0' };
      },
      async deleteEicDeployment(page, { clusterName, deployment }) {
        calls.push({ method: 'deleteEicDeployment', clusterName, deployment });
      },
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
      },
    });

    await assert.rejects(
      async () => await runTeardownFlow({
        page: makeFakePage(calls),
        steps: fakeSteps,
        inputs: { clusterName: 'test-cluster' },
        cells: [cellA, cellB],
        readNodeRecord: async () => {
          calls.push({ readNodeRecord: true });
          return { name: 'test-cluster', elmId: '12345' };
        },
        waitForLogin: async () => {},
        log: () => {},
        pollMs: 10,
        timeoutMs: 50,
      }),
      (err) => err instanceof SetupError && err.message.includes('pr-123-eic-b') && !err.message.includes('pr-123-eic-a'),
      'Should throw SetupError naming only pr-123-eic-b (still pending), not pr-123-eic-a (already gone)'
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('session_expired_after_node_opened_uses_goto_url', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const cell = {
      component: 'edge-icell',
      deployment: 'pr-123-eic',
      eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
      files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
    };

    let downloadElmZipCallCount = 0;
    let sessionExpiredCount = 0;

    const fakeSteps = makeFakeSteps({
      async edgeNodeState() { return 'absent'; },
      async addEdgeNode() {
        calls.push({ method: 'addEdgeNode' });
        currentUrl = capturedUrl;
      },
      async downloadElmZip(page, { dir }) {
        downloadElmZipCallCount++;
        calls.push({ method: 'downloadElmZip', callCount: downloadElmZipCallCount });
        if (downloadElmZipCallCount === 1) {
          // Session expires during download (after node opened)
          const error = new Error('Session expired');
          error.name = 'SessionExpiredError';
          throw error;
        }
        return join(dir, 'restricted-resources-elm.zip');
      },
      async setUpCloudConnector() { return join(dir, 'context.yaml'); },
      async deployEic() {},
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
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
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

    // Realistic page: the list URL until the node is added, then #/clusters/123
    const listUrl = 'https://example.com/#/';
    const capturedUrl = 'https://example.com/#/clusters/123';
    let currentUrl = listUrl;
    const fakePage = {
      url() { return currentUrl; },
      async goto(url) { calls.push({ goto: url }); currentUrl = url; },
      async reload() { calls.push({ reload: true }); },
    };

    const ctx = {
      page: fakePage,
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

    // Session expired during downloadElmZip (after the node was added): the retry
    // reopens with goto(captured #/clusters/<id> URL) after waitForLogin, never openEdgeNode
    assert.deepEqual(calls.slice(0, 6), [
      { method: 'addEdgeNode' },
      { method: 'downloadElmZip', callCount: 1 },
      { method: 'isSessionExpired', callCount: 1 },
      { waitForLogin: true },
      { goto: capturedUrl },
      { method: 'downloadElmZip', callCount: 2 },
    ]);
    assert.ok(!calls.some(c => c.method === 'openEdgeNode'), 'openEdgeNode should not be called (node URL captured after add)');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// Fake page that follows the ELM routes: the list URL until a node is opened or
// added, then `#/clusters/<id>`; goto() navigates to the given URL.
function makeRoutedPage(calls) {
  const listUrl = 'https://elm.example.com/#/';
  let currentUrl = listUrl;
  return {
    listUrl,
    nodeUrl: (id) => `https://elm.example.com/#/clusters/${id}`,
    showNode(id) { currentUrl = this.nodeUrl(id); },
    showList() { currentUrl = listUrl; },
    page: {
      url() { return currentUrl; },
      async goto(url) { calls.push({ goto: url }); currentUrl = url; },
      async reload() { calls.push({ reload: true }); },
    },
  };
}

function makeExpiringDeployCtx({ calls, dir, routed, steps, clusterEdgeNodeId = '' }) {
  const cell = {
    component: 'edge-icell',
    deployment: 'pr-123-eic',
    eic: { solution: 'Edge Integration Cell', version: '1.0.0', namespaces: { main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela', services: 'edge-icell-services', gateways: 'istio-gateways' }, virtualHost: 'eic.example.com', keyAlias: 'eic-key', sharedFsStorageClass: 'nfs-rwx', servicesDeployment: 'pr-123-eic-services', gatewaysDeployment: 'pr-123-eic-gateways' },
    files: { postgresCA: join(dir, 'postgres-ca.crt'), redisCA: join(dir, 'redis-ca.crt') },
  };
  return {
    page: routed.page,
    steps,
    isSteps: {
      async deployKeystore() {},
      async runtimeReady() { return true; },
      async deployArtifact() {},
      async artifactStates() {
        return { ipfilterAPI: 'Started', testAPI: 'Started', Arp_https: 'Started', SLV_FLOW_ELSTER: 'Started' };
      },
    },
    inputs: { clusterName: 'test-cluster', registry: {}, highAvailability: false, proxy: null },
    clusterEdgeNodeId,
    leftoverPolicy: 'delete',
    loadCells: async () => [cell],
    s3: { async put() {} },
    s3Prefix: 'test-prefix/',
    dir,
    waitForTask: async () => {},
    meshTask: 'configure-mesh-eic',
    loadKubeconfig: async () => 'kubeconfig',
    fetchElm: async () => join(dir, 'elm'),
    elmInit: async () => {},
    password: 'test-password',
    recordNode: async (record) => { calls.push({ recordNode: record }); },
    readNodeRecord: async () => null,
    waitForLogin: async () => { calls.push({ waitForLogin: true }); },
    log: () => {},
    pollMs: 10,
    timeoutMs: 100,
  };
}

// Deploy steps whose first downloadElmZip fails with an expired session.
function makeExpiringDeploySteps(calls, routed, overrides) {
  let downloadElmZipCallCount = 0;
  let sessionExpiredCount = 0;
  return makeFakeSteps({
    async edgeNodeElmId(page) {
      const match = page.url().match(/#\/clusters\/(\d+)/);
      if (!match) throw new SetupError('Cannot extract ELM node ID from URL.');
      return match[1];
    },
    async downloadElmZip(page, { dir }) {
      downloadElmZipCallCount++;
      calls.push({ method: 'downloadElmZip', callCount: downloadElmZipCallCount });
      if (downloadElmZipCallCount === 1) {
        throw new Error('Session expired');
      }
      return join(dir, 'restricted-resources-elm.zip');
    },
    async setUpCloudConnector(page, { dir }) { return join(dir, 'context.yaml'); },
    async deployEic() {},
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
    async openEdgeNode(page, clusterName) {
      calls.push({ method: 'openEdgeNode', clusterName });
    },
    ...overrides,
  });
}

test('fresh_run_expiry_after_add_goes_to_new_node_url', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const routed = makeRoutedPage(calls);
    const steps = makeExpiringDeploySteps(calls, routed, {
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'absent';
      },
      async addEdgeNode(page, { clusterName }) {
        calls.push({ method: 'addEdgeNode', clusterName });
        routed.showNode('456');
      },
    });

    const result = await runDeployFlow(makeExpiringDeployCtx({ calls, dir, routed, steps }));
    assert.equal(result, 'deployed');

    assert.deepEqual(calls.slice(0, 8), [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'addEdgeNode', clusterName: 'test-cluster' },
      { recordNode: { name: 'test-cluster', elmId: '456' } },
      { method: 'downloadElmZip', callCount: 1 },
      { method: 'isSessionExpired', callCount: 1 },
      { waitForLogin: true },
      { goto: routed.nodeUrl('456') },
      { method: 'downloadElmZip', callCount: 2 },
    ]);
    assert.ok(!calls.some(c => c.method === 'openEdgeNode'), 'openEdgeNode should never be called');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('leftover_deleted_and_re_added_expiry_goes_to_new_node_url', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const routed = makeRoutedPage(calls);
    const steps = makeExpiringDeploySteps(calls, routed, {
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        // The leftover node exists: edgeNodeState opens it (#/clusters/111)
        routed.showNode('111');
        return 'added';
      },
      async edgeNodeId() {
        calls.push({ method: 'edgeNodeId' });
        return 'old-cluster-456';
      },
      async removeEdgeNode(page, { clusterName }) {
        calls.push({ method: 'removeEdgeNode', clusterName });
        routed.showList();
      },
      async addEdgeNode(page, { clusterName }) {
        calls.push({ method: 'addEdgeNode', clusterName });
        routed.showNode('222');
      },
    });

    const result = await runDeployFlow(makeExpiringDeployCtx({ calls, dir, routed, steps, clusterEdgeNodeId: 'cluster-123' }));
    assert.equal(result, 'deployed');

    assert.deepEqual(calls.slice(0, 10), [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'edgeNodeId' },
      { method: 'removeEdgeNode', clusterName: 'test-cluster' },
      { method: 'addEdgeNode', clusterName: 'test-cluster' },
      { recordNode: { name: 'test-cluster', elmId: '222' } },
      { method: 'downloadElmZip', callCount: 1 },
      { method: 'isSessionExpired', callCount: 1 },
      { waitForLogin: true },
      { goto: routed.nodeUrl('222') },
      { method: 'downloadElmZip', callCount: 2 },
    ]);
    assert.ok(!calls.some(c => c.goto && c.goto.includes('/clusters/111')), 'never navigates to the deleted node 111');
    assert.ok(!calls.some(c => c.method === 'openEdgeNode'), 'openEdgeNode should never be called');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('upgrade_expiry_in_second_upgrade_goes_to_node_url', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const routed = makeRoutedPage(calls);
    const cells = [
      { component: 'edge-icell-1', deployment: 'pr-123-eic-1' },
      { component: 'edge-icell-2', deployment: 'pr-123-eic-2' },
    ];

    let upgradeCallCount = 0;
    let sessionExpiredCount = 0;
    const fakeSteps = makeFakeSteps({
      async openEdgeNode(page, clusterName) {
        calls.push({ method: 'openEdgeNode', clusterName });
        routed.showNode('333');
      },
      async upgradeEic(page, { deployment, version }) {
        upgradeCallCount++;
        calls.push({ method: 'upgradeEic', deployment, version });
        if (upgradeCallCount === 2) {
          throw new Error('Session expired');
        }
      },
      async isSessionExpired() {
        sessionExpiredCount++;
        calls.push({ method: 'isSessionExpired', callCount: sessionExpiredCount });
        return sessionExpiredCount === 1;
      },
      async eicDeploymentStatus(page, { deployment }) {
        calls.push({ method: 'eicDeploymentStatus', deployment });
        return { operation: 'Successful', status: 'Ready', version: '2.0.0' };
      },
    });

    const result = await runUpgradeFlow({
      page: routed.page,
      steps: fakeSteps,
      inputs: { clusterName: 'test-cluster' },
      cells,
      version: '2.0.0',
      s3: {},
      s3Prefix: 'test-prefix/',
      dir,
      waitForMarker: async () => {},
      waitForLogin: async () => { calls.push({ waitForLogin: true }); },
      log: () => {},
      pollMs: 10,
      timeoutMs: 100,
    });
    assert.equal(result, 'upgraded');

    assert.deepEqual(calls, [
      { method: 'openEdgeNode', clusterName: 'test-cluster' },
      { method: 'upgradeEic', deployment: 'pr-123-eic-1', version: '2.0.0' },
      { method: 'upgradeEic', deployment: 'pr-123-eic-2', version: '2.0.0' },
      { method: 'isSessionExpired', callCount: 1 },
      { waitForLogin: true },
      { goto: routed.nodeUrl('333') },
      { method: 'upgradeEic', deployment: 'pr-123-eic-2', version: '2.0.0' },
      { reload: true },
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-1' },
      { method: 'eicDeploymentStatus', deployment: 'pr-123-eic-2' },
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('expiry_during_add_retries_from_list', async () => {
  const calls = [];
  const dir = await mkdtemp(join(tmpdir(), 'elm-flow-test-'));
  try {
    const routed = makeRoutedPage(calls);
    let addCallCount = 0;
    const steps = makeExpiringDeploySteps(calls, routed, {
      async edgeNodeState(page, clusterName) {
        calls.push({ method: 'edgeNodeState', clusterName });
        return 'absent';
      },
      async addEdgeNode(page, { clusterName }) {
        addCallCount++;
        calls.push({ method: 'addEdgeNode', clusterName, callCount: addCallCount });
        if (addCallCount === 1) {
          throw new Error('Session expired');
        }
        routed.showNode('789');
      },
      async downloadElmZip(page, { dir }) {
        calls.push({ method: 'downloadElmZip' });
        return join(dir, 'restricted-resources-elm.zip');
      },
    });

    const result = await runDeployFlow(makeExpiringDeployCtx({ calls, dir, routed, steps }));
    assert.equal(result, 'deployed');

    // waitForLogin returns on the Edge Nodes list: addEdgeNode retries there, no node is opened
    assert.deepEqual(calls.slice(0, 7), [
      { method: 'edgeNodeState', clusterName: 'test-cluster' },
      { method: 'addEdgeNode', clusterName: 'test-cluster', callCount: 1 },
      { method: 'isSessionExpired', callCount: 1 },
      { waitForLogin: true },
      { method: 'addEdgeNode', clusterName: 'test-cluster', callCount: 2 },
      { recordNode: { name: 'test-cluster', elmId: '789' } },
      { method: 'downloadElmZip' },
    ]);
    assert.ok(!calls.some(c => c.method === 'openEdgeNode'), 'openEdgeNode should never be called');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
