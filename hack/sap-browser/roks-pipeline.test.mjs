// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG domcontentloaded

import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { access, mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { SetupError } from './inputs.mjs';
import { chromiumLaunchOptions, main, roksPipelineOptions } from './roks-pipeline.mjs';
import { finishSession } from './session.mjs';

const ELM = 'https://elm.example.com/';
const ROUTE_URL = 'https://roks-sap-browser-roks-c1.apps.example.com/vnc.html?autoconnect=1&resize=remote&path=websockify';
const SECRETS = ['pg-secret-value', 'aws-secret-value', 'context-secret-value', 'leaked-secret-value'];

async function folderTest(work) {
  const directory = await mkdtemp(join(tmpdir(), 'roks-pipeline-test-'));
  try { await work(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

function environment(directory, overrides = {}) {
  return {
    SAP_BROWSER_MODE: 'auto',
    SAP_BROWSER_PHASE: 'deploy',
    SAP_ELM_URL: ELM,
    PIPELINE_NAMESPACE: 'sap-edge-ci',
    PIPELINE_RUN: 'roks-run-1',
    PIPELINE_RUN_UID: 'run-uid-1',
    CLUSTER_NAME: 'roks-c1',
    POD_NAME: 'roks-run-1-sap-browser-deploy-pod',
    POD_UID: 'pod-uid-1',
    TASKRUN_NAME: 'roks-run-1-sap-browser-deploy',
    RUNNER_SERVICE_ACCOUNT: 'roks-sap-browser-runner',
    S3_PREFIX: 'restricted-resources/roks-c1/',
    BUCKET_HOST: 's3.openshift-storage.svc',
    BUCKET_PORT: '443',
    BUCKET_NAME: 'roks-bucket-1',
    AWS_ACCESS_KEY_ID: 'access-key-id',
    AWS_SECRET_ACCESS_KEY: 'aws-secret-value',
    POSTGRES_ADMIN_PASSWORD: 'pg-secret-value',
    CLUSTER_EDGE_NODE_ID: '',
    HUB_KUBECONFIG_SECRET_NAME: '',
    SAP_BROWSER_SESSION_DIR: directory,
    SAP_BROWSER_RESULT_PATH: join(directory, 'outcome'),
    ...overrides,
  };
}

// Fake browser, Route, S3 and cluster: no Chromium, no network.
function harness(overrides = {}) {
  const calls = [];
  const logs = [];
  const browser = new EventEmitter();
  browser.closed = false;
  browser.disconnect = () => {
    if (browser.closed) return;
    browser.closed = true;
    browser.emit('disconnected');
  };
  browser.close = async () => { calls.push('browser.close'); browser.disconnect(); };
  const page = {
    async goto(url, options) { calls.push(['goto', url, options?.waitUntil]); },
    async waitForURL(predicate) {
      if (!predicate(new URL(ELM))) throw new Error('unexpected origin');
      calls.push('login-url');
    },
    getByRole(role, options) {
      return { waitFor: async () => { calls.push(['login-heading', role, options.name]); } };
    },
    url() { return ELM; },
    async pause() { calls.push('pause'); },
    ...overrides.page,
  };
  const context = {
    setDefaultTimeout(ms) { calls.push(['default-timeout', ms]); },
    async newPage() { return page; },
  };
  browser.newContext = overrides.newContext ?? (async () => context);
  const s3 = { list: async () => [], get: async () => {}, put: async () => {} };
  const inputs = { clusterName: 'roks-c1', pipelineRun: 'roks-run-1', registry: {}, attachments: {} };
  const deps = {
    client: {
      async get(kind, name) { calls.push(['client.get', kind, name]); return { kind, name }; },
      async create() { throw new Error('unexpected create'); },
      async patch() { throw new Error('unexpected patch'); },
      async remove() { throw new Error('unexpected remove'); },
    },
    async openRoute(client, options) {
      calls.push(['openRoute', options]);
      return { url: ROUTE_URL, close: async () => { calls.push('route.close'); } };
    },
    async launchBrowser() { calls.push('launch'); return browser; },
    s3Factory(options) { calls.push(['s3Factory', options]); return s3; },
    flows: {
      async deploy(ctx) { calls.push(['deploy', ctx]); return 'deployed'; },
      async teardown(ctx) { calls.push(['teardown', ctx]); return 'edge-node-deleted'; },
    },
    steps: { name: 'fake-steps' },
    async loadRoksInputs(read, pipelineRun, options) {
      calls.push(['loadRoksInputs', read, pipelineRun, options]);
      return inputs;
    },
    async waitForPipelineTask(read, options) { calls.push(['waitForPipelineTask', read, options]); },
    async loadRestrictedKubeconfig(read, clusterName) {
      calls.push(['loadRestrictedKubeconfig', read, clusterName]);
      return 'restricted-kubeconfig';
    },
    async fetchElmCli(client, dir) { calls.push(['fetchElmCli', client, dir]); return join(dir, 'elm'); },
    async runElmInit(options) { calls.push(['runElmInit', options]); },
    contextPassword: () => 'context-secret-value',
    log: (line) => logs.push(String(line)),
    logError: (line) => logs.push(String(line)),
    finishInterval: 5,
    ...overrides.deps,
  };
  if (overrides.flows) deps.flows = { ...deps.flows, ...overrides.flows };
  return { deps, calls, logs, browser, page, s3, inputs };
}

function count(calls, name) {
  return calls.filter((call) => call === name).length;
}

function assertNoSecrets(logs) {
  const text = logs.join('\n');
  for (const secret of SECRETS) assert.ok(!text.includes(secret), `log contains ${secret}`);
}

async function waitForState(directory, expected) {
  for (let attempt = 0; attempt < 400; attempt++) {
    try {
      const status = JSON.parse(await readFile(join(directory, 'status.json'), 'utf8'));
      if (status.state === expected) return status;
    } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await delay(5);
  }
  assert.fail(`Session did not reach ${expected}`);
}

async function assertRemoved(path) {
  await assert.rejects(access(path), { code: 'ENOENT' });
}

test('rejects_prefix_mismatch', async () => folderTest(async (directory) => {
  assert.throws(() => roksPipelineOptions(environment(directory, { S3_PREFIX: 'restricted-resources/other/' })),
    (error) => error instanceof SetupError && /S3_PREFIX/.test(error.message));
  assert.throws(() => roksPipelineOptions(environment(directory, { S3_PREFIX: 'restricted-resources/roks-c1' })),
    SetupError);
  assert.equal(roksPipelineOptions(environment(directory)).s3Prefix, 'restricted-resources/roks-c1/');
}));

test('rejects_long_session', async () => folderTest(async (directory) => {
  assert.throws(() => roksPipelineOptions(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '241' })), SetupError);
  assert.throws(() => roksPipelineOptions(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '0' })), SetupError);
  assert.throws(() => roksPipelineOptions(environment(directory, {
    SAP_BROWSER_SESSION_MINUTES: '20', SAP_BROWSER_LOGIN_MINUTES: '21',
  })), SetupError);
  const defaults = roksPipelineOptions(environment(directory));
  assert.equal(defaults.sessionMinutes, 180);
  assert.equal(defaults.loginMinutes, 30);
  assert.equal(roksPipelineOptions(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '240' })).sessionMinutes, 240);
}));

test('options_validation', async () => folderTest(async (directory) => {
  const rejects = (overrides, pattern) => assert.throws(
    () => roksPipelineOptions(environment(directory, overrides)),
    (error) => error instanceof SetupError && pattern.test(error.message) && !SECRETS.some((s) => error.message.includes(s)),
  );
  rejects({ SAP_BROWSER_MODE: 'run' }, /mode/i);
  rejects({ SAP_BROWSER_PHASE: 'install' }, /phase/i);
  rejects({ SAP_ELM_URL: 'http://elm.example.com/' }, /HTTPS/);
  rejects({ SAP_ELM_URL: 'https://user:pw@elm.example.com/' }, /credentials/);
  rejects({ CLUSTER_NAME: 'Bad_Name' }, /CLUSTER_NAME/);
  rejects({ POD_UID: '' }, /POD_UID/);
  rejects({ PWDEBUG: '1' }, /debug/i);
  rejects({ DEBUG: 'pw:api' }, /debug/i);
  rejects({ POSTGRES_ADMIN_PASSWORD: '' }, /POSTGRES_ADMIN_PASSWORD/);
  rejects({ AWS_SECRET_ACCESS_KEY: '' }, /AWS_SECRET_ACCESS_KEY/);
  rejects({ BUCKET_PORT: '99999' }, /BUCKET_PORT/);
  // The admin password and bucket are only needed when the deploy flow runs.
  for (const overrides of [{ SAP_BROWSER_MODE: 'inspect' }, { SAP_BROWSER_PHASE: 'teardown' }]) {
    const options = roksPipelineOptions(environment(directory, {
      ...overrides, POSTGRES_ADMIN_PASSWORD: '', AWS_SECRET_ACCESS_KEY: '', BUCKET_HOST: '',
    }));
    assert.equal(options.clusterName, 'roks-c1');
  }
  for (const id of ['', 'unknown', 'Edge-Node-42']) {
    assert.equal(roksPipelineOptions(environment(directory, { CLUSTER_EDGE_NODE_ID: id })).clusterEdgeNodeId, id);
  }
}));

test('chromium_env_is_minimal', async () => folderTest(async (directory) => {
  const display = {
    DISPLAY: ':99',
    PATH: '/usr/local/bin:/usr/bin:/bin',
    HOME: '/home/runner',
    XDG_RUNTIME_DIR: '/tmp/sap-browser-session/xdg-runtime',
    XDG_CONFIG_HOME: '/tmp/sap-browser-session/xdg-config',
    XDG_CACHE_HOME: '/tmp/sap-browser-session/xdg-cache',
    TMPDIR: '/tmp/sap-browser-session',
    LANG: 'C.UTF-8',
  };
  const options = chromiumLaunchOptions({ ...environment(directory), ...display });
  // Exactly the display/locale keys that are set; no credentials, URLs or run metadata.
  assert.deepEqual(options.env, display);
  for (const key of ['AWS_SECRET_ACCESS_KEY', 'AWS_ACCESS_KEY_ID', 'POSTGRES_ADMIN_PASSWORD', 'SAP_ELM_URL']) {
    assert.ok(!Object.hasOwn(options.env, key), `${key} reaches Chromium`);
  }
  assert.ok(!Object.values(options.env).some((value) => SECRETS.includes(value)));
  assert.equal(options.headless, false);
  assert.deepEqual(options.args, ['--window-size=1440,900']);
  // LC_ALL and TZ pass through only when set.
  assert.deepEqual(chromiumLaunchOptions({ ...display, LC_ALL: 'C.UTF-8', TZ: 'UTC' }).env,
    { ...display, LC_ALL: 'C.UTF-8', TZ: 'UTC' });
}));

test('hub_skips_without_browser', async () => folderTest(async (directory) => {
  const h = harness();
  const outcome = await main(environment(directory, { HUB_KUBECONFIG_SECRET_NAME: 'hub-kubeconfig' }), h.deps);
  assert.equal(outcome, 'skipped-hub');
  assert.equal(count(h.calls, 'launch'), 0);
  assert.ok(!h.calls.some((call) => call[0] === 'openRoute' || call[0] === 'loadRoksInputs'));
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'skipped-hub');
  assert.match(h.logs.join('\n'), /hub/i);
}));

test('inspect_outcome', async () => folderTest(async (directory) => {
  const h = harness();
  const outcome = await main(environment(directory, { SAP_BROWSER_MODE: 'inspect' }), h.deps);
  assert.equal(outcome, 'inspection-finished');
  assert.equal(count(h.calls, 'pause'), 1);
  assert.ok(!h.calls.some((call) => call[0] === 'deploy' || call[0] === 'teardown' || call[0] === 'loadRoksInputs'));
  // Same login checks as pipeline.mjs: ELM origin, then the Edge Nodes heading.
  assert.ok(h.calls.some((call) => call[0] === 'goto' && call[1] === ELM && call[2] === 'domcontentloaded'));
  assert.ok(h.calls.includes('login-url'));
  assert.ok(h.calls.some((call) => call[0] === 'login-heading' && call[2] === 'Edge Nodes'));
  assert.ok(h.calls.indexOf('pause') > h.calls.indexOf('login-url'));
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'inspection-finished');
}));

test('auto_deploy_outcome', async () => folderTest(async (directory) => {
  const seen = {};
  const h = harness({
    flows: {
      async deploy(ctx) {
        seen.ctx = ctx;
        seen.dirMode = (await stat(ctx.dir)).mode & 0o777;
        await ctx.waitForTask('generate-sa-based-kubeconfig');
        seen.kubeconfig = await ctx.loadKubeconfig();
        seen.elmPath = await ctx.fetchElm(ctx.dir);
        await ctx.elmInit({ elmPath: seen.elmPath, contextFile: join(ctx.dir, 'context.cfg'), password: ctx.password, cwd: ctx.dir });
        return 'deployed';
      },
    },
  });
  const outcome = await main(environment(directory, { CLUSTER_EDGE_NODE_ID: 'unknown' }), h.deps);
  assert.equal(outcome, 'deployed');
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'deployed');

  const { ctx } = seen;
  assert.equal(ctx.page, h.page);
  assert.equal(ctx.steps, h.deps.steps);
  assert.equal(ctx.inputs, h.inputs);
  assert.equal(ctx.clusterEdgeNodeId, 'unknown');
  assert.equal(ctx.s3, h.s3);
  assert.equal(ctx.s3Prefix, 'restricted-resources/roks-c1/');
  assert.equal(ctx.password, 'context-secret-value');
  assert.equal(typeof ctx.log, 'function');
  assert.ok(ctx.dir.startsWith(join(directory, '')), 'work dir lives in the session dir');
  assert.equal(seen.dirMode, 0o700);
  await assertRemoved(ctx.dir);

  const [, read, pipelineRun, inputOptions] = h.calls.find((call) => call[0] === 'loadRoksInputs');
  assert.equal(pipelineRun, 'roks-run-1');
  assert.deepEqual(inputOptions, {
    expectedRunUID: 'run-uid-1', expectedClusterName: 'roks-c1', postgresPassword: 'pg-secret-value',
  });
  assert.deepEqual(await read('secret', 'eic-registry-roks-roks-c1'), { kind: 'secret', name: 'eic-registry-roks-roks-c1' });

  const [, routeOptions] = h.calls.find((call) => call[0] === 'openRoute');
  assert.deepEqual(routeOptions, {
    name: 'roks-sap-browser-roks-c1',
    podName: 'roks-run-1-sap-browser-deploy-pod',
    podUID: 'pod-uid-1',
    taskRunName: 'roks-run-1-sap-browser-deploy',
    serviceAccount: 'roks-sap-browser-runner',
  });
  assert.ok(h.logs.includes(`Open ${ROUTE_URL}, log in to OpenShift, then log in to SAP in the browser shown.`));

  const [, s3Options] = h.calls.find((call) => call[0] === 's3Factory');
  assert.deepEqual(s3Options, {
    endpoint: 'https://s3.openshift-storage.svc:443',
    bucket: 'roks-bucket-1',
    credentials: { accessKeyId: 'access-key-id', secretAccessKey: 'aws-secret-value' },
    home: ctx.dir,
  });

  const [, waitRead, waitOptions] = h.calls.find((call) => call[0] === 'waitForPipelineTask');
  assert.equal(typeof waitRead, 'function');
  assert.equal(waitOptions.pipelineRun, 'roks-run-1');
  assert.equal(waitOptions.pipelineRunUID, 'run-uid-1');
  assert.equal(waitOptions.pipelineTaskName, 'generate-sa-based-kubeconfig');
  assert.ok(waitOptions.signal instanceof AbortSignal);

  const [, kubeconfigRead, kubeconfigCluster] = h.calls.find((call) => call[0] === 'loadRestrictedKubeconfig');
  assert.equal(typeof kubeconfigRead, 'function');
  assert.equal(kubeconfigCluster, 'roks-c1');
  assert.equal(seen.kubeconfig, 'restricted-kubeconfig');

  const [, fetchClient, fetchDir] = h.calls.find((call) => call[0] === 'fetchElmCli');
  assert.equal(fetchClient, h.s3);
  assert.equal(fetchDir, ctx.dir);

  const [, initOptions] = h.calls.find((call) => call[0] === 'runElmInit');
  assert.equal(initOptions.elmPath, join(ctx.dir, 'elm'));
  assert.equal(initOptions.password, 'context-secret-value');
  assert.equal(initOptions.cwd, ctx.dir);

  assert.equal(count(h.calls, 'route.close'), 1);
  assert.equal(count(h.calls, 'browser.close'), 1);
  assertNoSecrets(h.logs);
}));

test('auto_teardown_outcome', async () => folderTest(async (directory) => {
  for (const result of ['edge-node-deleted', 'nothing-to-delete']) {
    const h = harness({ flows: { async teardown(ctx) { h.calls.push(['teardown', ctx]); return result; } } });
    const env = environment(directory, { SAP_BROWSER_PHASE: 'teardown', POSTGRES_ADMIN_PASSWORD: '' });
    assert.equal(await main(env, h.deps), result);
    const [, ctx] = h.calls.find((call) => call[0] === 'teardown');
    assert.equal(ctx.page, h.page);
    assert.equal(ctx.steps, h.deps.steps);
    assert.equal(ctx.clusterName, 'roks-c1');
    assert.equal(typeof ctx.log, 'function');
    assert.ok(!h.calls.some((call) => call[0] === 'loadRoksInputs' || call[0] === 's3Factory'));
    assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), result);
  }
}));

test('flow_failure_hands_over', async () => folderTest(async (directory) => {
  const h = harness({
    flows: { async deploy() { throw new SetupError('ELM screen step not mapped yet: edgeNodeState.'); } },
  });
  const running = main(environment(directory), h.deps);
  const status = await waitForState(directory, 'failed');
  assert.equal(status.clusterName, 'roks-c1');
  await delay(30);
  // The logged-in browser and its Route stay up for the user to finish by hand.
  assert.equal(count(h.calls, 'browser.close'), 0);
  assert.equal(count(h.calls, 'route.close'), 0);
  assert.ok(h.logs.includes('ELM screen step not mapped yet: edgeNodeState.'));
  await finishSession(directory); // what `control.mjs finish` does
  assert.equal(await running, 'handed-over');
  assert.equal(count(h.calls, 'browser.close'), 1);
  assert.equal(count(h.calls, 'route.close'), 1);
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'handed-over');
  assertNoSecrets(h.logs);
}));

test('handover_ends_when_chromium_closed', async () => folderTest(async (directory) => {
  // A Playwright error during the flow is a flow failure too; its text is never printed.
  const h = harness({ flows: { async deploy() { throw new Error('locator.fill("leaked-secret-value") timed out'); } } });
  const running = main(environment(directory), h.deps);
  await waitForState(directory, 'failed');
  h.browser.disconnect(); // the user closes Chromium
  assert.equal(await running, 'handed-over');
  assert.equal(count(h.calls, 'route.close'), 1);
  assertNoSecrets(h.logs);
}));

test('unexpected_error_is_failed_not_thrown', async () => folderTest(async (directory) => {
  const failures = [
    { deps: { async launchBrowser() { throw new Error('leaked-secret-value'); } } },
    { deps: { async loadRoksInputs() { throw new TypeError('leaked-secret-value'); } } },
    { newContext: async () => { throw new Error('leaked-secret-value'); } },
  ];
  for (const failure of failures) {
    const h = harness(failure);
    const outcome = await main(environment(directory), h.deps);
    assert.equal(outcome, 'failed');
    assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'failed');
    assertNoSecrets(h.logs);
  }
  // Even a failing result write does not reject.
  const h = harness();
  const outcome = await main(environment(directory, { SAP_BROWSER_RESULT_PATH: join(directory, 'missing', 'outcome') }), h.deps);
  assert.equal(outcome, 'deployed');
}));

test('route_closed_on_every_path', async () => folderTest(async (directory) => {
  const scenarios = {
    deployed: { expected: 'deployed' },
    teardown: { expected: 'nothing-to-delete', env: { SAP_BROWSER_PHASE: 'teardown' },
      overrides: { flows: { teardown: async () => 'nothing-to-delete' } } },
    inspect: { expected: 'inspection-finished', env: { SAP_BROWSER_MODE: 'inspect' } },
    'invalid flow outcome': { expected: 'handed-over', finish: true,
      overrides: { flows: { deploy: async () => 'registration-reviewed' } } },
    'flow failure': { expected: 'handed-over', finish: true,
      overrides: { flows: { deploy: async () => { throw new SetupError('step failed'); } } } },
    'login timeout': { expected: 'failed',
      overrides: { page: { waitForURL: async () => { throw new Error('Timeout 1800000ms exceeded'); } } } },
    'wrong tenant': { expected: 'failed', overrides: { page: { url: () => 'https://other.example.com/' } } },
    'pause error': { expected: 'failed', env: { SAP_BROWSER_MODE: 'inspect' },
      overrides: { page: { pause: async () => { throw new Error('Target closed'); } } } },
    'unexpected error': { expected: 'failed', overrides: { newContext: async () => { throw new Error('boom'); } } },
  };
  for (const [name, scenario] of Object.entries(scenarios)) {
    // A fresh session dir per scenario: no status or finish file carries over.
    const session = await mkdtemp(join(directory, 'case-'));
    const h = harness(scenario.overrides);
    const running = main(environment(session, scenario.env), h.deps);
    if (scenario.finish) {
      await waitForState(session, 'failed');
      await finishSession(session);
    }
    assert.equal(await running, scenario.expected, name);
    assert.equal(count(h.calls, 'route.close'), 1, `${name}: Route closed once`);
    assert.equal(count(h.calls, 'browser.close'), 1, `${name}: browser closed once`);
  }

  // Chromium closed during the automation (no hand-over possible) stops the session.
  {
    let ctxDir;
    const h = harness({
      flows: {
        async deploy(ctx) {
          ctxDir = ctx.dir;
          h.browser.disconnect();
          await ctx.waitForTask('configure-mesh-eic');
          return 'deployed';
        },
      },
      deps: {
        async waitForPipelineTask(read, { signal }) {
          await new Promise((resolve, reject) => {
            if (signal.aborted) reject(signal.reason);
            signal.addEventListener('abort', () => reject(signal.reason), { once: true });
          });
        },
      },
    });
    assert.equal(await main(environment(directory), h.deps), 'failed');
    assert.equal(count(h.calls, 'route.close'), 1);
    assert.ok(h.logs.includes('Chromium was closed before the session finished.'));
    await assertRemoved(ctxDir);
  }

  // A Route that cannot be opened (openRoute cleans itself up) never starts Chromium.
  {
    const h = harness({ deps: { async openRoute() { throw new SetupError('Route was not admitted within the timeout period.'); } } });
    assert.equal(await main(environment(directory), h.deps), 'failed');
    assert.equal(count(h.calls, 'launch'), 0);
    assert.ok(h.logs.includes('Route was not admitted within the timeout period.'));
  }
}));

test('result_file_written', async () => folderTest(async (directory) => {
  const resultPath = join(directory, 'outcome');
  const invalid = harness();
  assert.equal(await main(environment(directory, { SAP_BROWSER_MODE: 'run' }), invalid.deps), 'failed');
  assert.equal(await readFile(resultPath, 'utf8'), 'failed');
  assert.equal(count(invalid.calls, 'launch'), 0);
  assert.ok(!invalid.calls.some((call) => call[0] === 'openRoute'));

  const ok = harness();
  assert.equal(await main(environment(directory), ok.deps), 'deployed');
  assert.equal(await readFile(resultPath, 'utf8'), 'deployed');
  assert.equal((await stat(resultPath)).mode & 0o777, 0o600);
}));
