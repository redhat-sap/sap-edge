// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG domcontentloaded

import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { access, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { runBrowserTask } from './browser-session.mjs';
import { runDeployFlow } from './elm-flow.mjs';
import { SetupError } from './inputs.mjs';
import { chromiumLaunchOptions, main, roksPipelineOptions, roksProfile } from './roks-pipeline.mjs';
import { finishSession } from './session.mjs';

const ELM = 'https://elm.example.com/';
const ROUTE_URL = 'https://sapb-roks-c1-sap-edge-ci.apps.example.com/vnc.html?autoconnect=1&resize=remote&path=websockify';
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
    POD_SERVICE_ACCOUNT: 'roks-sap-browser-runner',
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
  rejects({ POD_SERVICE_ACCOUNT: '' }, /POD_SERVICE_ACCOUNT/);
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

test('rejects_pod_without_runner_service_account', async () => folderTest(async (directory) => {
  // Without the run file's taskRunSpecs the pod runs as the pipeline SA
  assert.throws(() => roksPipelineOptions(environment(directory, { POD_SERVICE_ACCOUNT: 'pipeline' })), (error) =>
    error instanceof SetupError &&
    error.message === 'The browser pod runs as pipeline, not roks-sap-browser-runner: add the taskRunSpecs from the run file.');
  // Also in inspect mode and for the teardown phase
  for (const overrides of [{ SAP_BROWSER_MODE: 'inspect' }, { SAP_BROWSER_PHASE: 'teardown' }]) {
    assert.throws(() => roksPipelineOptions(environment(directory, { ...overrides, POD_SERVICE_ACCOUNT: 'pipeline' })), SetupError);
  }
  assert.equal(roksPipelineOptions(environment(directory)).serviceAccount, 'roks-sap-browser-runner');
}));

test('wrong_pod_service_account_fails_without_route', async () => folderTest(async (directory) => {
  const h = harness();
  const outcome = await main(environment(directory, { POD_SERVICE_ACCOUNT: 'pipeline' }), h.deps);
  assert.equal(outcome, 'failed');
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'failed');
  assert.ok(!h.calls.some((call) => call[0] === 'openRoute' || call[0] === 'loadRoksInputs' || call === 'launch'),
    `no Route, inputs or browser: ${JSON.stringify(h.calls.map((call) => (Array.isArray(call) ? call[0] : call)))}`);
  assert.ok(h.logs.includes('The browser pod runs as pipeline, not roks-sap-browser-runner: add the taskRunSpecs from the run file.'),
    h.logs.join('\n'));
  assertNoSecrets(h.logs);
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
  // Login checks: ELM origin, then the Edge Nodes heading.
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
    name: 'sapb-roks-c1',
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
    assert.equal(ctx.inputs.clusterName, 'roks-c1');
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

// In-memory bucket: put/get go through real files like the aws CLI does.
function memoryS3() {
  const objects = new Map();
  return {
    objects,
    async put(file, key) { objects.set(key, await readFile(file, 'utf8')); },
    async get(key, file) {
      if (!objects.has(key)) throw new SetupError('S3 operation failed. Check endpoint, bucket and permissions.');
      await writeFile(file, objects.get(key));
    },
    async list(prefix) { return [...objects.keys()].filter((key) => key.startsWith(prefix)).map((key) => ({ key })); },
  };
}

// ELM steps for the real deploy flow up to the EIC deployment.
function deploySteps(calls, overrides = {}) {
  return {
    async isSessionExpired() { return false; },
    async openEdgeNode() { calls.push('openEdgeNode'); },
    async edgeNodeState() { calls.push('edgeNodeState'); return 'absent'; },
    async addEdgeNode() { calls.push('addEdgeNode'); },
    async edgeNodeElmId() { return '4711'; },
    async downloadElmZip(page, { dir }) {
      const file = join(dir, 'restricted-resources-roks-c1-elm.zip');
      await writeFile(file, 'elm-zip');
      return file;
    },
    async setUpCloudConnector(page, { dir }) {
      const file = join(dir, 'context.cfg');
      await writeFile(file, 'context');
      return file;
    },
    async deployEic() { calls.push('deployEic'); },
    ...overrides,
  };
}

test('playwright_error_in_step_hands_over', async () => folderTest(async (directory) => {
  const h = harness({
    flows: { deploy: runDeployFlow },
    deps: { steps: deploySteps([], { async edgeNodeState() { throw new Error('secret-value'); } }) },
  });
  const running = main(environment(directory), h.deps);
  await waitForState(directory, 'failed');
  assert.equal(count(h.calls, 'browser.close'), 0, 'the browser stays open for the user');
  await finishSession(directory);
  assert.equal(await running, 'handed-over');
  assert.equal(await readFile(join(directory, 'outcome'), 'utf8'), 'handed-over');
  assert.ok(!h.logs.join('\n').includes('secret-value'), h.logs.join('\n'));
  assert.ok(h.logs.includes('Unexpected error; details are hidden because they can contain credentials.'));
}));

test('session_limit_from_profile', async () => folderTest(async (directory) => {
  assert.equal(roksProfile.sessionLimitMinutes, 240);
  const h = harness();
  assert.equal(await main(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '241' }), h.deps), 'failed');
  assert.equal(count(h.calls, 'launch'), 0);
  assert.ok(!h.calls.some((call) => call[0] === 'openRoute' || call[0] === 'loadRoksInputs'));
  assert.ok(h.logs.includes('Session must be 1-240 minutes; login time must fit inside the session.'), h.logs.join('\n'));

  // The session enforces the profile's limit even when the options accept more.
  const strict = harness();
  const profile = { ...roksProfile, sessionLimitMinutes: 60 };
  assert.equal(await runBrowserTask(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '61' }), strict.deps, profile), 'failed');
  assert.equal(count(strict.calls, 'launch'), 0);
  assert.ok(strict.logs.includes('Session must be 1-60 minutes; login time must fit inside the session.'), strict.logs.join('\n'));
  const fits = harness();
  assert.equal(await runBrowserTask(environment(directory, { SAP_BROWSER_SESSION_MINUTES: '60' }), fits.deps,
    { ...profile, loadInputs: async () => fits.inputs }), 'deployed');
}));

test('roks_deploy_hands_over_at_eic', async () => folderTest(async (directory) => {
  const calls = [];
  const s3 = memoryS3();
  const h = harness({
    flows: { deploy: runDeployFlow },
    deps: { steps: deploySteps(calls), s3Factory: () => s3 },
  });
  const running = main(environment(directory), h.deps);
  await waitForState(directory, 'failed');
  await finishSession(directory);
  assert.equal(await running, 'handed-over');
  assert.ok(h.logs.includes('EIC form values for edge-icell are not mapped yet; deploy EIC by hand'), h.logs.join('\n'));
  assert.ok(!calls.includes('deployEic'), 'nothing is deployed');
  // The flow got through the Edge Node and the Cloud Connector first.
  assert.deepEqual(JSON.parse(s3.objects.get('restricted-resources/roks-c1/.browser/edge-node.json')), { name: 'roks-c1', elmId: '4711' });
  assert.equal(s3.objects.get('restricted-resources/roks-c1/elm/restricted-resources-roks-c1-elm.zip'), 'elm-zip');
  assert.ok(h.calls.some((call) => call[0] === 'runElmInit'));
  assert.ok(h.calls.some((call) => call[0] === 'waitForPipelineTask' && call[2].pipelineTaskName === 'generate-sa-based-kubeconfig'));
  assert.ok(h.logs.some((line) => line.includes('restricted-resources/roks-c1/elm/ and restricted-resources/roks-c1/edge-icell/')), h.logs.join('\n'));
  assertNoSecrets(h.logs);
}));

test('roks_profile_shape', async () => folderTest(async (directory) => {
  assert.equal(roksProfile.name, 'roks');
  assert.equal(roksProfile.hub, 'skip');
  assert.equal(roksProfile.leftoverPolicy, 'delete');
  assert.equal(roksProfile.meshTask, 'configure-mesh-eic');
  const options = roksPipelineOptions(environment(directory));
  assert.deepEqual(roksProfile.handOverFolders(options), ['elm/', 'edge-icell/']);
  const cells = await roksProfile.loadCells(() => { throw new Error('no reads'); }, options, {});
  assert.equal(cells.length, 1);
  assert.equal(cells[0].component, 'edge-icell');
  assert.equal(cells[0].eic, null);
}));

test('phase_from_env', async () => folderTest(async (directory) => {
  assert.equal(roksPipelineOptions(environment(directory, { SAP_BROWSER_PHASE: '' })).phase, 'deploy');
  assert.equal(roksPipelineOptions(environment(directory, { SAP_BROWSER_PHASE: 'teardown' })).phase, 'teardown');
  // ROKS has no upgrade window.
  assert.throws(() => roksPipelineOptions(environment(directory, { SAP_BROWSER_PHASE: 'upgrade' })),
    (error) => error instanceof SetupError && error.message === 'SAP browser phase must be deploy or teardown.');
}));

test('session_records_node_in_bucket', async () => folderTest(async (directory) => {
  const s3 = memoryS3();
  const seen = {};
  const h = harness({
    deps: { s3Factory: () => s3, pollMs: 5 },
    flows: {
      async deploy(ctx) {
        seen.before = await ctx.readNodeRecord();
        await ctx.recordNode({ name: 'roks-c1', elmId: '4711' });
        seen.after = await ctx.readNodeRecord();
        seen.ctx = ctx;
        // A record for another node is not this run's record.
        s3.objects.set('restricted-resources/roks-c1/.browser/edge-node.json', JSON.stringify({ name: 'other', elmId: '4711' }));
        seen.other = await ctx.readNodeRecord();
        s3.objects.set('restricted-resources/roks-c1/.browser/edge-node.json', 'not json');
        seen.invalid = await ctx.readNodeRecord().catch((error) => error);
        return 'deployed';
      },
    },
  });
  assert.equal(await main(environment(directory), h.deps), 'deployed');
  assert.equal(seen.before, null);
  assert.deepEqual(seen.after, { name: 'roks-c1', elmId: '4711' });
  assert.equal(seen.other, null);
  assert.ok(seen.invalid instanceof SetupError, String(seen.invalid));
  const { ctx } = seen;
  assert.equal(ctx.leftoverPolicy, 'delete');
  assert.equal(ctx.meshTask, 'configure-mesh-eic');
  assert.equal(typeof ctx.waitForLogin, 'function');
  assert.equal(ctx.pollMs, 5);
  assert.ok(ctx.timeoutMs > 0 && ctx.timeoutMs <= 180 * 60000);
  assert.deepEqual((await ctx.loadCells()).map((cell) => cell.component), ['edge-icell']);
}));

test('upgrade_and_teardown_ctx', async () => folderTest(async (directory) => {
  // A profile with an upgrade window (ROKS has none): the session loads the cells and passes the version.
  const s3 = memoryS3();
  const upgradeProfile = {
    ...roksProfile,
    options: (env) => ({ ...roksPipelineOptions(env), phase: 'upgrade', upgradeVersion: '8.49.1' }),
  };
  const marker = 'restricted-resources/roks-c1/.applied/restricted-resources-roks-c1-eic-8.49.1.zip';
  let markerWaited = false;
  const up = harness({
    deps: { s3Factory: () => s3, pollMs: 5 },
    flows: {
      async upgrade(ctx) {
        up.calls.push(['upgrade', ctx]);
        // The marker appears while the session polls the bucket for it.
        const waiting = ctx.waitForMarker(marker).then(() => { markerWaited = true; });
        await delay(20);
        assert.equal(markerWaited, false, 'waits until the marker exists');
        s3.objects.set(marker, '');
        await waiting;
        return 'upgraded';
      },
    },
  });
  assert.equal(await runBrowserTask(environment(directory), up.deps, upgradeProfile), 'upgraded');
  assert.ok(markerWaited);
  const [, upgradeCtx] = up.calls.find((call) => call[0] === 'upgrade');
  assert.equal(upgradeCtx.version, '8.49.1');
  assert.deepEqual(upgradeCtx.inputs, { clusterName: 'roks-c1' });
  assert.deepEqual(upgradeCtx.cells.map((cell) => cell.component), ['edge-icell']);
  assert.equal(upgradeCtx.s3, s3);
  assert.equal(typeof upgradeCtx.waitForMarker, 'function');
  assert.ok(!up.calls.some((call) => call[0] === 'loadRoksInputs'), 'upgrade needs only the cluster name');

  // ROKS teardown has no bucket: no ownership record, so an existing node is handed over.
  const down = harness({
    flows: {
      async teardown(ctx) {
        down.calls.push(['teardown', ctx]);
        await ctx.readNodeRecord();
        return 'edge-node-deleted';
      },
    },
  });
  const running = main(environment(directory, { SAP_BROWSER_PHASE: 'teardown' }), down.deps);
  await waitForState(directory, 'failed');
  await finishSession(directory);
  assert.equal(await running, 'handed-over');
  const [, teardownCtx] = down.calls.find((call) => call[0] === 'teardown');
  assert.deepEqual(teardownCtx.inputs, { clusterName: 'roks-c1' });
  assert.deepEqual(teardownCtx.cells.map((cell) => cell.component), ['edge-icell']);
  assert.ok(down.logs.includes('No bucket for the Edge Node ownership record in this phase; remove the Edge Node by hand.'), down.logs.join('\n'));
}));
