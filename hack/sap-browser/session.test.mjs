// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { executeFlow, finishSession, managedSession, writeStatus } from './session.mjs';
import { pipelineOptions } from './pipeline.mjs';

async function folderTest(work) {
  const directory = await mkdtemp(join(tmpdir(), 'sap-session-test-'));
  try { await work(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

async function waitForState(directory, expected) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const status = JSON.parse(await readFile(join(directory, 'status.json'), 'utf8'));
      if (status.state === expected) return status;
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    await delay(10);
  }
  assert.fail(`Session did not reach ${expected}`);
}

test('preview waits for explicit finish and reports review, not deployment success', async () => folderTest(async (directory) => {
  await writeStatus(directory, 'waiting-for-login');
  await assert.rejects(finishSession(directory), /still working/);
  const resultPath = join(directory, 'result');
  const session = managedSession({
    directory, signal: AbortSignal.timeout(2000), resultPath, interval: 5,
    metadata: { pipelineRun: 'run-1' }, work: async () => 'registration-reviewed',
  });
  const status = await waitForState(directory, 'registration-reviewed');
  assert.equal(status.pipelineRun, 'run-1');
  await assert.rejects(readFile(resultPath), { code: 'ENOENT' });
  await finishSession(directory);
  assert.equal(await session, 'registration-reviewed');
  assert.equal(await readFile(resultPath, 'utf8'), 'registration-reviewed');
}));

test('finishing a failed browser flow cannot report success or expose credential errors', async (t) => folderTest(async (directory) => {
  const messages = [];
  t.mock.method(console, 'error', (value) => messages.push(value));
  const resultPath = join(directory, 'result');
  const session = managedSession({
    directory, signal: AbortSignal.timeout(2000), resultPath, interval: 5,
    work: async () => { throw new Error('fill failed for secret-password-value'); },
  });
  const rejected = assert.rejects(session, /automation failure/);
  await waitForState(directory, 'failed');
  await finishSession(directory);
  await rejected;
  assert.equal(messages.join(' ').includes('secret-password-value'), false);
  await assert.rejects(readFile(resultPath), { code: 'ENOENT' });
}));

test('session expiration does not produce a successful task result', async () => folderTest(async (directory) => {
  const abort = new AbortController();
  const resultPath = join(directory, 'result');
  const session = managedSession({
    directory, signal: abort.signal, resultPath, interval: 5,
    work: async () => 'registration-reviewed',
  });
  const rejected = assert.rejects(session, /abort/i);
  await waitForState(directory, 'registration-reviewed');
  abort.abort();
  await rejected;
  await assert.rejects(readFile(resultPath), { code: 'ENOENT' });
}));

test('a deployment flow must verify readiness explicitly', async () => {
  for (const result of [undefined, false, 'true']) {
    await assert.rejects(executeFlow({ run: async () => {}, verify: async () => result }, {}), /verification failed/);
  }
  await assert.rejects(executeFlow({ run: async () => {} }, {}), /export/);
  assert.equal(await executeFlow({ run: async () => {}, verify: async () => true }, {}), 'deployment-verified');
});

test('pipeline mode validates run identity, deadlines, tenant and custom flow selection', () => {
  const env = {
    SAP_BROWSER_MODE: 'review-registration', SAP_ELM_URL: 'https://tenant.example.test',
    PIPELINE_NAMESPACE: 'pipelines', PIPELINE_RUN: 'run-1', PIPELINE_RUN_UID: 'uid-1', HOSTED_CLUSTER_NAME: 'hcp-demo',
  };
  assert.equal(pipelineOptions(env).sessionMinutes, 120);
  for (const values of [
    { PIPELINE_RUN_UID: '' }, { HOSTED_CLUSTER_NAME: '../another' },
    { SAP_ELM_URL: 'http://tenant.example.test' }, { SAP_ELM_URL: 'https://user:password@tenant.example.test' },
    { SAP_BROWSER_MODE: 'run' }, { SAP_BROWSER_MODE: 'unexpected' },
    { SAP_BROWSER_SESSION_MINUTES: '5', SAP_BROWSER_LOGIN_MINUTES: '10' },
    { SAP_BROWSER_SESSION_MINUTES: 'NaN' }, { SAP_BROWSER_FLOW: 'flow.mjs' },
    { SAP_BROWSER_HA: 'guess' }, { PWDEBUG: '1' },
  ]) assert.throws(() => pipelineOptions({ ...env, ...values }));
  assert.equal(pipelineOptions({ ...env, SAP_BROWSER_MODE: 'run', SAP_BROWSER_FLOW: 'flow.mjs' }).mode, 'run');
});
