// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG

import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { runBrowserTask } from './browser-session.mjs';
import { hcpPipelineOptions, hcpProfile, main } from './hcp-pipeline.mjs';
import { SetupError } from './inputs.mjs';

const ELM = 'https://elm.example.com/';
const ROUTE_URL = 'https://sapb-hcp-c1-sap-edge-ci.apps.example.com/vnc.html?autoconnect=1&resize=remote&path=websockify';
const SINGLE = 'hcp-ossm3-validation-pipeline';
const DEDICATED = 'hcp-ossm3-dedicated-validation-pipeline';
const SECRETS = ['pg-secret-value', 'redis-secret-value', 'robot-secret-value', 'aws-secret-value', 'admin-kubeconfig-value'];

async function folderTest(work) {
  const directory = await mkdtemp(join(tmpdir(), 'hcp-pipeline-test-'));
  try { await work(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

function environment(directory, overrides = {}) {
  return {
    SAP_BROWSER_MODE: 'auto',
    SAP_BROWSER_PHASE: 'deploy',
    SAP_ELM_URL: ELM,
    PIPELINE_NAMESPACE: 'sap-edge-ci',
    PIPELINE_RUN: 'hcp-run-1',
    PIPELINE_RUN_UID: 'run-uid-1',
    HOSTED_CLUSTER_NAME: 'hcp-c1',
    POD_NAME: 'hcp-run-1-sap-browser-deploy-pod',
    POD_UID: 'pod-uid-1',
    TASKRUN_NAME: 'hcp-run-1-sap-browser-deploy',
    RUNNER_SERVICE_ACCOUNT: 'hcp-sap-browser-runner',
    POD_SERVICE_ACCOUNT: 'hcp-sap-browser-runner',
    S3_PREFIX: 'restricted-resources/multi-eic/',
    CELL_COUNT: '2',
    DATASTORE_TYPE: 'redis',
    HIGH_AVAILABILITY: 'false',
    DEPLOYMENT_NAME_PREFIX: 'pr-7',
    SAP_EIC_SOLUTION: 'Edge Integration Cell (dev)',
    SAP_EIC_KEY_ALIAS: 'slv-ic',
    SAP_EIC_INSTALL_VERSION: '',
    SAP_EIC_UPGRADE_VERSION: '',
    REGISTRY_SECRET: 'eli-quay-robot',
    PROXY_CONFIGURED: 'false',
    BUCKET_HOST: 's3.openshift-storage.svc',
    BUCKET_PORT: '443',
    BUCKET_NAME: 'hcp-bucket-1',
    AWS_ACCESS_KEY_ID: 'access-key-id',
    AWS_SECRET_ACCESS_KEY: 'aws-secret-value',
    CLUSTER_EDGE_NODE_ID: '',
    HUB_KUBECONFIG_SECRET_NAME: '',
    SAP_BROWSER_SESSION_DIR: directory,
    SAP_BROWSER_RESULT_PATH: join(directory, 'outcome'),
    ...overrides,
  };
}

const base64 = (value) => Buffer.from(value).toString('base64');

function secret(data) {
  return { data: Object.fromEntries(Object.entries(data).map(([key, value]) => [key, base64(value)])) };
}

function credentials(suffix, overrides = {}) {
  return {
    'postgres-host': 'edgedb-primary.sap-eic-external-postgres.svc',
    'postgres-port': '5432',
    'postgres-dbname': 'edgedb',
    'postgres-user': 'edgedb',
    'postgres-password': 'pg-secret-value',
    'postgres-tls-root-cert': 'postgres-ca-pem',
    'redis-address': `redb-headless.sap-eic-external-redis${suffix}.svc:6379`,
    'redis-password': 'redis-secret-value',
    'redis-server-name': `rec.sap-eic-external-redis${suffix}.svc.cluster.local`,
    'redis-tls-cert': `redis-ca-pem${suffix}`,
    'ingress-domain': 'd',
    ...overrides,
  };
}

// The pipeline namespace as the per-run Role lets the runner see it.
function cluster({ pipeline = DEDICATED, cells = ['-eic-1', '-eic-2'], overrides = {} } = {}) {
  const resources = new Map([
    ['pipelinerun/hcp-run-1', {
      metadata: { uid: 'run-uid-1' },
      spec: { pipelineRef: { name: pipeline }, params: [{ name: 'hostedClusterName', value: 'hcp-c1' }] },
    }],
    ['secret/eli-quay-robot', secret({
      registry: 'quay.apps.eli.example.com', username: 'robot', password: 'robot-secret-value', 'ca.crt': 'registry-ca-pem',
    })],
    ['secret/edgelm-kubeconfig-generated-hcp-c1', secret({ kubeconfig: 'restricted-kubeconfig' })],
  ]);
  for (const suffix of cells) {
    resources.set(`secret/eic-credentials-hcp-hcp-c1${suffix}`, secret({ ...credentials(suffix), kubeconfig: 'admin-kubeconfig-value' }));
  }
  for (const [key, value] of Object.entries(overrides)) resources.set(key, value);
  const reads = [];
  const read = async (kind, name) => {
    reads.push(`${kind}/${name}`);
    const resource = resources.get(`${kind}/${name}`);
    if (!resource) throw new SetupError(`Cannot read ${kind}/${name}.`);
    return resource;
  };
  return { resources, reads, read };
}

// Fake browser, Route and bucket around a fake cluster: no Chromium, no network.
function harness({ cluster: fakeCluster = cluster(), flows = {}, deps = {} } = {}) {
  const calls = [];
  const logs = [];
  const browser = new EventEmitter();
  browser.close = async () => { calls.push('browser.close'); browser.emit('disconnected'); };
  const page = {
    async goto() {},
    async waitForURL(predicate) { if (!predicate(new URL(ELM))) throw new Error('unexpected origin'); },
    getByRole() { return { waitFor: async () => {} }; },
    url() { return ELM; },
    async pause() { calls.push('pause'); },
  };
  browser.newContext = async () => ({ setDefaultTimeout() {}, async newPage() { return page; } });
  const s3 = { list: async () => [], get: async () => {}, put: async () => {} };
  return {
    calls, logs, cluster: fakeCluster, s3,
    deps: {
      client: {
        get: fakeCluster.read,
        async create() { throw new Error('unexpected create'); },
        async patch() { throw new Error('unexpected patch'); },
        async remove() { throw new Error('unexpected remove'); },
      },
      async openRoute(client, options) {
        calls.push(['openRoute', options]);
        return { url: ROUTE_URL, close: async () => { calls.push('route.close'); } };
      },
      async launchBrowser() { calls.push('launch'); return browser; },
      s3Factory() { return s3; },
      async waitForPipelineTask(read, options) { calls.push(['waitForPipelineTask', options.pipelineTaskName]); },
      flows: {
        async deploy(ctx) { calls.push(['deploy', ctx, await ctx.loadCells()]); return 'deployed'; },
        async upgrade(ctx) { calls.push(['upgrade', ctx]); return 'upgraded'; },
        async teardown(ctx) { calls.push(['teardown', ctx]); return 'edge-node-deleted'; },
        ...flows,
      },
      steps: { name: 'fake-steps' },
      contextPassword: () => 'context-secret-value',
      log: (line) => logs.push(String(line)),
      logError: (line) => logs.push(String(line)),
      finishInterval: 5,
      ...deps,
    },
  };
}

function waits(calls) {
  return calls.filter((call) => call[0] === 'waitForPipelineTask').map((call) => call[1]);
}

function assertNoSecrets(logs) {
  const text = logs.join('\n');
  for (const value of SECRETS) assert.ok(!text.includes(value), `log contains ${value}`);
}

// Loads the cells straight from the profile, recording the pipeline tasks it waits for.
async function loadCells(directory, envOverrides = {}, fakeCluster = cluster()) {
  const waited = [];
  const options = hcpPipelineOptions(environment(directory, envOverrides));
  const cells = await hcpProfile.loadCells(fakeCluster.read, options, {
    waitForTask: async (name) => { waited.push(name); }, dir: directory,
  });
  return { cells, waited, options };
}

test('hcp_runs_with_hub', async () => folderTest(async (directory) => {
  const h = harness();
  const outcome = await main(environment(directory, { HUB_KUBECONFIG_SECRET_NAME: 'eli-kubeconfig' }), h.deps);
  assert.equal(outcome, 'deployed', h.logs.join('\n'));
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'deployed');
  assert.ok(h.calls.includes('launch'));
  const [, ctx, cells] = h.calls.find((call) => call[0] === 'deploy');
  assert.equal(ctx.inputs.clusterName, 'hcp-c1');
  assert.equal(ctx.leftoverPolicy, 'hand-over');
  assert.equal(ctx.meshTask, 'configure-mesh-eic');
  assert.equal(ctx.s3Prefix, 'restricted-resources/multi-eic/');
  assert.deepEqual(cells.map((cell) => cell.deployment), ['pr-7-eic-1', 'pr-7-eic-2']);
  assert.equal(await ctx.loadKubeconfig(), 'restricted-kubeconfig');
  const [, routeOptions] = h.calls.find((call) => call[0] === 'openRoute');
  assert.equal(routeOptions.name, 'sapb-hcp-c1');
  assert.equal(routeOptions.serviceAccount, 'hcp-sap-browser-runner');
  assert.ok(!h.logs.some((line) => /hub/i.test(line)), h.logs.join('\n'));
  assertNoSecrets(h.logs);
}));

test('cells_follow_cell_count', async () => folderTest(async (directory) => {
  const fakeCluster = cluster({ cells: ['-eic-1'] });
  const { cells, waited } = await loadCells(directory, { CELL_COUNT: '1' }, fakeCluster);
  assert.deepEqual(waited, ['cell1-get-all-accesses']);
  assert.deepEqual(cells.map((cell) => cell.deployment), ['pr-7-eic-1']);
  assert.ok(!fakeCluster.reads.some((name) => name.endsWith('-eic-2')), fakeCluster.reads.join(', '));
  assert.deepEqual(hcpProfile.handOverFolders(hcpPipelineOptions(environment(directory, { CELL_COUNT: '1' }))), ['elm/', 'edge-icell-1/']);

  // Through the session: the upgrade loads the cells before the browser exists.
  const h = harness({ cluster: cluster({ cells: ['-eic-1'] }) });
  const states = [];
  h.deps.waitForPipelineTask = async (read, options) => {
    h.calls.push(['waitForPipelineTask', options.pipelineTaskName]);
    states.push(JSON.parse(await readFile(join(directory, 'status.json'), 'utf8')).state);
  };
  const get = h.deps.client.get;
  h.deps.client.get = async (kind, name) => {
    if (kind === 'secret') states.push(JSON.parse(await readFile(join(directory, 'status.json'), 'utf8')).state);
    return get(kind, name);
  };
  const openRoute = h.deps.openRoute;
  h.deps.openRoute = async (client, options) => {
    states.push(JSON.parse(await readFile(join(directory, 'status.json'), 'utf8')).state);
    return openRoute(client, options);
  };
  const env = environment(directory, { CELL_COUNT: '1', SAP_BROWSER_PHASE: 'upgrade', SAP_EIC_UPGRADE_VERSION: '8.49.1' });
  assert.equal(await main(env, h.deps), 'upgraded', h.logs.join('\n'));
  assert.deepEqual(waits(h.calls), ['cell1-get-all-accesses']);
  // Not 'automating' before the browser exists.
  assert.deepEqual(states, ['waiting-for-pipeline', 'loading-inputs', 'opening-route']);
  const [, ctx] = h.calls.find((call) => call[0] === 'upgrade');
  assert.equal(ctx.version, '8.49.1');
  assert.deepEqual(ctx.cells.map((cell) => cell.component), ['edge-icell-1']);
}));

test('two_cells_names', async () => folderTest(async (directory) => {
  const { cells, waited } = await loadCells(directory);
  assert.deepEqual(waited, ['cell1-get-all-accesses', 'cell2-get-all-accesses']);
  assert.equal(cells.length, 2);
  for (const [index, cell] of cells.entries()) {
    const n = index + 1;
    assert.deepEqual(cell, {
      component: `edge-icell-${n}`,
      deployment: `pr-7-eic-${n}`,
      eic: {
        solution: 'Edge Integration Cell (dev)',
        version: '',
        namespaces: {
          main: `edge-icell-${n}`,
          secrets: `edge-icell-secrets-${n}`,
          ela: `edge-icell-ela-${n}`,
          services: `edge-icell-services-${n}`,
          gateways: `istio-gateways-${n}`,
        },
        virtualHost: `eic-${n}.d`,
        keyAlias: 'slv-ic',
        sharedFsStorageClass: 'nfs-rwx',
        servicesDeployment: `pr-7-eic-${n}-services`,
        gatewaysDeployment: `pr-7-eic-${n}-gateways`,
      },
      services: {
        postgres: {
          host: 'edgedb-primary.sap-eic-external-postgres.svc', port: '5432', database: 'edgedb',
          username: 'edgedb', password: 'pg-secret-value',
        },
        datastore: {
          type: 'redis', address: `redb-headless.sap-eic-external-redis-eic-${n}.svc:6379`,
          password: 'redis-secret-value', serverName: `rec.sap-eic-external-redis-eic-${n}.svc.cluster.local`,
          mode: 'standalone', username: '',
        },
      },
      files: { postgresCA: cell.files.postgresCA, redisCA: cell.files.redisCA },
    });
    assert.ok(cell.files.postgresCA.startsWith(join(directory, '')));
    assert.notEqual(cell.files.postgresCA, cells[1 - index].files.postgresCA, 'one CA file per cell');
    assert.equal(await readFile(cell.files.postgresCA, 'utf8'), 'postgres-ca-pem');
    assert.equal(await readFile(cell.files.redisCA, 'utf8'), `redis-ca-pem-eic-${n}`);
    for (const file of Object.values(cell.files)) assert.equal((await stat(file)).mode & 0o777, 0o600);
  }
  // Versions and the storage class come from the options.
  const set = await loadCells(directory, { SAP_EIC_INSTALL_VERSION: '8.48.2', SHARED_FS_STORAGE_CLASS: 'ocs-cephfs' });
  assert.equal(set.cells[0].eic.version, '8.48.2');
  assert.equal(set.cells[0].eic.sharedFsStorageClass, 'ocs-cephfs');
  assert.deepEqual(hcpProfile.handOverFolders(set.options), ['elm/', 'edge-icell-1/', 'edge-icell-2/']);
}));

test('single_eic_plain_names', async () => folderTest(async (directory) => {
  const fakeCluster = cluster({ pipeline: SINGLE, cells: [''] });
  const { cells, waited, options } = await loadCells(directory, { CELL_COUNT: '' }, fakeCluster);
  assert.deepEqual(waited, ['get-all-accesses']);
  assert.ok(fakeCluster.reads.includes('secret/eic-credentials-hcp-hcp-c1'));
  assert.equal(cells.length, 1);
  const [cell] = cells;
  assert.equal(cell.component, 'edge-icell');
  assert.equal(cell.deployment, 'pr-7-eic');
  assert.deepEqual(cell.eic.namespaces, {
    main: 'edge-icell', secrets: 'edge-icell-secrets', ela: 'edge-icell-ela',
    services: 'edge-icell-services', gateways: 'istio-gateways',
  });
  assert.equal(cell.eic.virtualHost, 'eic.d');
  assert.equal(cell.eic.servicesDeployment, 'pr-7-eic-services');
  assert.equal(cell.eic.gatewaysDeployment, 'pr-7-eic-gateways');
  assert.deepEqual(hcpProfile.handOverFolders(options), ['elm/', 'edge-icell/']);

  // Valkey keys for a Valkey run.
  const valkey = cluster({
    pipeline: SINGLE, cells: [],
    overrides: {
      'secret/eic-credentials-hcp-hcp-c1': secret({
        ...credentials(''), 'redis-address': '', 'redis-tls-cert': '',
        'valkey-address': 'valkey-headless:6379', 'valkey-password': 'redis-secret-value', 'valkey-mode': 'cluster',
        'valkey-server-name': 'valkey-headless.svc.cluster.local', 'valkey-tls-cert': 'valkey-ca-pem',
      }),
    },
  });
  const loaded = await loadCells(directory, { CELL_COUNT: '', DATASTORE_TYPE: 'valkey-cluster' }, valkey);
  assert.equal(loaded.cells[0].services.datastore.mode, 'cluster');
  assert.equal(loaded.cells[0].services.datastore.address, 'valkey-headless:6379');
  assert.equal(await readFile(loaded.cells[0].files.redisCA, 'utf8'), 'valkey-ca-pem');
}));

test('registry_from_hub_secret', async () => folderTest(async (directory) => {
  const fakeCluster = cluster();
  const options = hcpPipelineOptions(environment(directory, { HIGH_AVAILABILITY: 'true' }));
  const inputs = await hcpProfile.loadInputs(fakeCluster.read, options, { dir: directory });
  assert.deepEqual(inputs, {
    clusterName: 'hcp-c1',
    pipelineRun: 'hcp-run-1',
    highAvailability: true,
    proxy: false,
    registry: {
      url: 'quay.apps.eli.example.com', username: 'robot', password: 'robot-secret-value',
      caCertificateFile: join(directory, 'registry-ca.crt'),
    },
  });
  assert.equal(await readFile(inputs.registry.caCertificateFile, 'utf8'), 'registry-ca-pem');
  assert.equal((await stat(inputs.registry.caCertificateFile)).mode & 0o777, 0o600);
  // Only this run's PipelineRun and the registry Secret.
  assert.deepEqual(fakeCluster.reads, ['pipelinerun/hcp-run-1', 'secret/eli-quay-robot']);

  // A missing key names the field, never a value.
  const broken = cluster({ overrides: { 'secret/eli-quay-robot': secret({ registry: 'quay', username: 'robot', password: 'robot-secret-value' }) } });
  await assert.rejects(hcpProfile.loadInputs(broken.read, options, { dir: directory }),
    (error) => error instanceof SetupError && /ca\.crt/.test(error.message) && !error.message.includes('robot-secret-value'));

  // Through the session the deploy flow gets the registry; the CA file lives in the work dir.
  const h = harness();
  assert.equal(await main(environment(directory), h.deps), 'deployed', h.logs.join('\n'));
  const [, ctx] = h.calls.find((call) => call[0] === 'deploy');
  assert.equal(ctx.inputs.registry.caCertificateFile, join(ctx.dir, 'registry-ca.crt'));
}));

test('proxy_flag', async () => folderTest(async (directory) => {
  const fakeCluster = cluster();
  for (const [value, expected] of [['true', true], ['false', false], [undefined, false]]) {
    const options = hcpPipelineOptions(environment(directory, { PROXY_CONFIGURED: value }));
    assert.equal(options.proxy, expected);
    assert.equal((await hcpProfile.loadInputs(fakeCluster.read, options, { dir: directory })).proxy, expected);
  }
  assert.throws(() => hcpPipelineOptions(environment(directory, { PROXY_CONFIGURED: 'yes' })),
    (error) => error instanceof SetupError && /PROXY_CONFIGURED/.test(error.message));
}));

test('kubeconfig_key_never_read', async () => folderTest(async (directory) => {
  const touched = [];
  const fakeCluster = cluster();
  for (const suffix of ['-eic-1', '-eic-2']) {
    const credentialSecret = fakeCluster.resources.get(`secret/eic-credentials-hcp-hcp-c1${suffix}`);
    Object.defineProperty(credentialSecret.data, 'kubeconfig', {
      enumerable: true,
      get() { touched.push(suffix); return base64('admin-kubeconfig-value'); },
    });
  }
  const { cells } = await loadCells(directory, {}, fakeCluster);
  assert.deepEqual(touched, []);
  assert.ok(!JSON.stringify(cells).includes('admin-kubeconfig-value'));
  assert.ok(!JSON.stringify(cells).includes(base64('admin-kubeconfig-value')));

  // The restricted kubeconfig comes from its own Secret.
  const options = hcpPipelineOptions(environment(directory));
  assert.equal(await hcpProfile.loadKubeconfig(fakeCluster.read, options), 'restricted-kubeconfig');
  assert.equal(fakeCluster.reads.at(-1), 'secret/edgelm-kubeconfig-generated-hcp-c1');

  // Without ingress-domain (before Task 10's get-all-accesses) the error names the Secret.
  const old = cluster({ overrides: { 'secret/eic-credentials-hcp-hcp-c1-eic-1': secret({ ...credentials('-eic-1'), 'ingress-domain': '' }) } });
  await assert.rejects(loadCells(directory, {}, old),
    (error) => error instanceof SetupError && error.message.includes('eic-credentials-hcp-hcp-c1-eic-1') && /ingress-domain/.test(error.message));
}));

test('rejects_other_pipeline', async () => folderTest(async (directory) => {
  const options = hcpPipelineOptions(environment(directory));
  const rejected = async (fakeCluster, pattern, opts = options) => {
    await assert.rejects(hcpProfile.loadInputs(fakeCluster.read, opts, { dir: directory }),
      (error) => error instanceof SetupError && pattern.test(error.message));
    await assert.rejects(hcpProfile.loadCells(fakeCluster.read, opts, { waitForTask: async () => {}, dir: directory }),
      (error) => error instanceof SetupError && pattern.test(error.message));
  };
  await rejected(cluster({ pipeline: 'hcp-ossm3-multi-stack-validation-pipeline' }), /hcp-ossm3-dedicated-validation-pipeline/);
  await rejected(cluster({ pipeline: 'roks-eic-ossm3-pipeline' }), /pipeline/);
  // cellCount '' belongs to the single-EIC pipeline, a cell count to the dedicated one.
  await rejected(cluster({ pipeline: DEDICATED }), /hcp-ossm3-validation-pipeline/, hcpPipelineOptions(environment(directory, { CELL_COUNT: '' })));
  await rejected(cluster({ pipeline: SINGLE }), /hcp-ossm3-dedicated-validation-pipeline/);
  // Another run or another cluster.
  await rejected(cluster({ overrides: { 'pipelinerun/hcp-run-1': { metadata: { uid: 'other' }, spec: { pipelineRef: { name: DEDICATED } } } } }), /UID/);
  await rejected(cluster({
    overrides: { 'pipelinerun/hcp-run-1': { metadata: { uid: 'run-uid-1' }, spec: { pipelineRef: { name: DEDICATED }, params: [{ name: 'hostedClusterName', value: 'other' }] } } },
  }), /cluster/i);

  // Pipelines as Code embeds the pipeline: the embedded spec must have the tasks the session waits for.
  const inline = (names) => cluster({
    overrides: {
      'pipelinerun/hcp-run-1': {
        metadata: { uid: 'run-uid-1' },
        spec: { pipelineSpec: { tasks: names.map((name) => ({ name })) }, params: [{ name: 'hostedClusterName', value: 'hcp-c1' }] },
      },
    },
  });
  const dedicatedTasks = ['generate-sa-based-kubeconfig', 'cell1-get-all-accesses', 'cell2-get-all-accesses', 'configure-mesh-eic'];
  assert.equal((await loadCells(directory, {}, inline(dedicatedTasks))).cells.length, 2);
  // The multi-stack pipeline has no generate-sa-based-kubeconfig or configure-mesh-eic.
  await rejected(inline(['stack1-generate-sa-based-kubeconfig', 'cell1-get-all-accesses', 'cell2-get-all-accesses']), /pipeline/);
  await rejected(inline(['generate-sa-based-kubeconfig', 'get-all-accesses', 'configure-mesh-eic']), /pipeline/);

  // Through the session: failed, no browser.
  const h = harness({ cluster: cluster({ pipeline: 'hcp-ossm3-multi-stack-validation-pipeline' }) });
  assert.equal(await main(environment(directory), h.deps), 'failed');
  assert.ok(!h.calls.includes('launch'));
  assertNoSecrets(h.logs);
}));

test('rejects_bad_s3_prefix', async () => folderTest(async (directory) => {
  for (const prefix of ['restricted-resources/', 'restricted-resources/multi-eic', 'other/multi-eic/', 'restricted-resources/../x/',
    'restricted-resources/Multi/', 'restricted-resources/a/b/', '', undefined]) {
    assert.throws(() => hcpPipelineOptions(environment(directory, { S3_PREFIX: prefix })),
      (error) => error instanceof SetupError && /S3_PREFIX/.test(error.message), String(prefix));
  }
  assert.equal(hcpPipelineOptions(environment(directory, { S3_PREFIX: 'restricted-resources/hcp-c1.v2/' })).s3Prefix,
    'restricted-resources/hcp-c1.v2/');
}));

test('session_limit_600', async () => folderTest(async (directory) => {
  assert.equal(hcpProfile.sessionLimitMinutes, 600);
  const defaults = hcpPipelineOptions(environment(directory));
  assert.equal(defaults.sessionMinutes, 360);
  assert.equal(defaults.loginMinutes, 30);
  assert.equal(hcpPipelineOptions(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '600' })).sessionMinutes, 600);
  for (const overrides of [
    { SAP_BROWSER_SESSION_MINUTES: '601' }, { SAP_BROWSER_SESSION_MINUTES: '0' },
    { SAP_BROWSER_SESSION_MINUTES: '20', SAP_BROWSER_LOGIN_MINUTES: '21' },
  ]) {
    assert.throws(() => hcpPipelineOptions(environment(directory, overrides)), SetupError);
  }
  const h = harness();
  assert.equal(await main(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '601' }), h.deps), 'failed');
  assert.ok(!h.calls.includes('launch'));
  assert.ok(h.logs.includes('Session must be 1-600 minutes; login time must fit inside the session.'), h.logs.join('\n'));
}));

test('hcp_profile_shape', async () => folderTest(async (directory) => {
  assert.equal(hcpProfile.name, 'hcp');
  assert.equal(hcpProfile.hub, 'ignore');
  assert.equal(hcpProfile.leftoverPolicy, 'hand-over');
  assert.equal(hcpProfile.meshTask, 'configure-mesh-eic');
  assert.deepEqual(hcpProfile.pipelines, [SINGLE, DEDICATED]);
  assert.equal(hcpProfile.options, hcpPipelineOptions);
  // The profile drives the shared session.
  const h = harness();
  assert.equal(await runBrowserTask(environment(directory, { SAP_BROWSER_MODE: 'inspect' }), h.deps, hcpProfile), 'inspection-finished');
  assert.ok(h.calls.includes('pause'));
  assert.deepEqual(h.cluster.reads, [], 'inspect reads nothing');
}));

test('options_validation', async () => folderTest(async (directory) => {
  const rejects = (overrides, pattern) => assert.throws(
    () => hcpPipelineOptions(environment(directory, overrides)),
    (error) => error instanceof SetupError && pattern.test(error.message) && !SECRETS.some((value) => error.message.includes(value)),
    JSON.stringify(overrides),
  );
  rejects({ SAP_BROWSER_MODE: 'run' }, /mode/i);
  rejects({ SAP_BROWSER_PHASE: 'install' }, /phase/i);
  rejects({ SAP_ELM_URL: 'http://elm.example.com/' }, /HTTPS/);
  rejects({ HOSTED_CLUSTER_NAME: 'Bad_Name' }, /HOSTED_CLUSTER_NAME/);
  rejects({ POD_SERVICE_ACCOUNT: 'pipeline' }, /taskRunSpecs/);
  rejects({ PWDEBUG: '1' }, /debug/i);
  rejects({ CELL_COUNT: '0' }, /CELL_COUNT/);
  rejects({ CELL_COUNT: '10' }, /CELL_COUNT/);
  rejects({ CELL_COUNT: undefined }, /CELL_COUNT/);
  rejects({ DATASTORE_TYPE: 'memcached' }, /DATASTORE_TYPE/);
  rejects({ HIGH_AVAILABILITY: 'yes' }, /HIGH_AVAILABILITY/);
  rejects({ DEPLOYMENT_NAME_PREFIX: 'hcp-c1' }, /DEPLOYMENT_NAME_PREFIX/);
  rejects({ DEPLOYMENT_NAME_PREFIX: 'pr-' }, /DEPLOYMENT_NAME_PREFIX/);
  rejects({ SAP_EIC_KEY_ALIAS: '' }, /SAP_EIC_KEY_ALIAS/);
  rejects({ SAP_EIC_INSTALL_VERSION: '8.48 2' }, /SAP_EIC_INSTALL_VERSION/);
  rejects({ SAP_EIC_UPGRADE_VERSION: '$(params.x)' }, /SAP_EIC_UPGRADE_VERSION/);
  rejects({ SAP_EIC_SOLUTION: 'Edge\nIntegration Cell' }, /SAP_EIC_SOLUTION/);
  rejects({ REGISTRY_SECRET: '' }, /REGISTRY_SECRET/);
  rejects({ SHARED_FS_STORAGE_CLASS: 'NFS RWX' }, /SHARED_FS_STORAGE_CLASS/);
  rejects({ AWS_SECRET_ACCESS_KEY: '' }, /AWS_SECRET_ACCESS_KEY/);
  rejects({ BUCKET_PORT: '99999' }, /BUCKET_PORT/);
  const options = hcpPipelineOptions(environment(directory, { SAP_EIC_UPGRADE_VERSION: '8.49.1', SAP_BROWSER_PHASE: 'upgrade' }));
  assert.equal(options.phase, 'upgrade');
  assert.equal(options.upgradeVersion, '8.49.1');
  assert.equal(options.clusterName, 'hcp-c1');
  assert.equal(options.cellCount, 2);
  assert.deepEqual(options.bucket, {
    endpoint: 'https://s3.openshift-storage.svc:443', name: 'hcp-bucket-1',
    credentials: { accessKeyId: 'access-key-id', secretAccessKey: 'aws-secret-value' },
  });
  // Inspect needs neither the bucket nor the EIC values.
  const inspect = hcpPipelineOptions(environment(directory, {
    SAP_BROWSER_MODE: 'inspect', AWS_SECRET_ACCESS_KEY: '', BUCKET_HOST: '', SAP_EIC_KEY_ALIAS: '', REGISTRY_SECRET: '',
  }));
  assert.equal(inspect.bucket, undefined);
  // Teardown needs no registry Secret.
  assert.equal(hcpPipelineOptions(environment(directory, { SAP_BROWSER_PHASE: 'teardown', REGISTRY_SECRET: '' })).phase, 'teardown');
  for (const id of ['', 'unknown', 'Edge-Node-42']) {
    assert.equal(hcpPipelineOptions(environment(directory, { CLUSTER_EDGE_NODE_ID: id })).clusterEdgeNodeId, id);
  }
}));
