// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { SetupError } from './inputs.mjs';

export const terminalStates = ['registration-reviewed', 'inspection-finished', 'deployment-verified', 'failed'];

export async function writeStatus(directory, state, metadata = {}) {
  const temporary = join(directory, 'status.tmp');
  await writeFile(temporary, JSON.stringify({ ...metadata, state }, null, 2) + '\n', { mode: 0o600 });
  await rename(temporary, join(directory, 'status.json'));
}

export async function finishSession(directory) {
  const status = JSON.parse(await readFile(join(directory, 'status.json'), 'utf8'));
  if (!terminalStates.includes(status.state)) {
    throw new SetupError('The session is still working. Wait for review, inspection, verification, or failure.');
  }
  await writeFile(join(directory, 'finish'), '', { mode: 0o600 });
}

export async function waitForFinish(directory, signal, interval = 500) {
  while (true) {
    signal.throwIfAborted();
    try { await readFile(join(directory, 'finish')); return; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await delay(interval, undefined, { signal });
  }
}

// Preserve the live browser after an automation failure for inspection, but never
// turn it into a successful task just because the user closes the session.
export async function managedSession({ directory, metadata, signal, work, resultPath, interval }) {
  await rm(join(directory, 'finish'), { force: true });
  let outcome;
  let failed = false;
  try {
    outcome = await work();
    if (!terminalStates.includes(outcome) || outcome === 'failed') {
      throw new SetupError('The browser flow did not produce a valid outcome.');
    }
    await writeStatus(directory, outcome, metadata);
  } catch (error) {
    if (signal.aborted) throw error;
    failed = true;
    await writeStatus(directory, 'failed', metadata);
    console.error('Browser automation failed. Inspect the browser before finishing; this task will fail.');
    if (error instanceof SetupError) console.error(error.message);
  }
  await waitForFinish(directory, signal, interval);
  if (failed) throw new SetupError('Browser session finished after an automation failure.');
  signal.throwIfAborted();
  if (resultPath) await writeFile(resultPath, outcome, { mode: 0o600 });
  return outcome;
}

export async function executeFlow(flow, args) {
  if (typeof flow.run !== 'function' || typeof flow.verify !== 'function') {
    throw new SetupError('Flow must export run() and verify().');
  }
  await flow.run(args);
  if (await flow.verify(args) !== true) throw new SetupError('Deployment readiness verification failed.');
  return 'deployment-verified';
}
