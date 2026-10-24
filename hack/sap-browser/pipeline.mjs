// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG domcontentloaded

import { realpath } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import { inClusterReader } from './cluster-reader.mjs';
import { loadInputs, SetupError, withPrivateFiles } from './inputs.mjs';
import { reviewRegistration } from './registration.mjs';
import { executeFlow, managedSession, writeStatus } from './session.mjs';

export function pipelineOptions(env) {
  const mode = env.SAP_BROWSER_MODE;
  if (!['inspect', 'review-registration', 'run'].includes(mode)) throw new SetupError('Invalid SAP browser mode.');
  let url;
  try { url = new URL(env.SAP_ELM_URL); } catch { throw new SetupError('Set sapElmUrl to the ELM HTTPS URL.'); }
  if (url.protocol !== 'https:' || url.username || url.password) throw new SetupError('Use an ELM HTTPS URL without credentials.');
  const namePattern = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;
  for (const key of ['PIPELINE_NAMESPACE', 'PIPELINE_RUN', 'HOSTED_CLUSTER_NAME']) {
    if (!namePattern.test(env[key] ?? '')) throw new SetupError(`Missing or invalid ${key}.`);
  }
  if (!/^[a-zA-Z0-9-]+$/.test(env.PIPELINE_RUN_UID ?? '')) throw new SetupError('Missing PipelineRun UID.');
  const sessionMinutes = Number(env.SAP_BROWSER_SESSION_MINUTES || 120);
  const loginMinutes = Number(env.SAP_BROWSER_LOGIN_MINUTES || 30);
  if (!Number.isFinite(sessionMinutes) || sessionMinutes < 1 || sessionMinutes > 120 ||
      !Number.isFinite(loginMinutes) || loginMinutes < 1 || loginMinutes > sessionMinutes) {
    throw new SetupError('Session must be 1-120 minutes; login time must fit inside the session.');
  }
  if (!['true', 'false'].includes(env.SAP_BROWSER_HA || 'false')) throw new SetupError('sapBrowserHA must be true or false.');
  if (mode === 'run' && !env.SAP_BROWSER_FLOW) throw new SetupError('Run mode requires sapBrowserFlow.');
  if (mode !== 'run' && env.SAP_BROWSER_FLOW) throw new SetupError('sapBrowserFlow is only used with run mode.');
  if (env.PWDEBUG || env.DEBUG?.includes('pw:')) throw new SetupError('Disable Playwright debug logging before handling credentials.');
  return {
    mode, url: url.href, namespace: env.PIPELINE_NAMESPACE,
    pipelineRun: env.PIPELINE_RUN, pipelineRunUID: env.PIPELINE_RUN_UID,
    clusterName: env.HOSTED_CLUSTER_NAME, sessionMinutes, loginMinutes,
    highAvailability: env.SAP_BROWSER_HA === 'true', flow: env.SAP_BROWSER_FLOW,
    directory: env.SAP_BROWSER_SESSION_DIR || '/tmp/sap-browser-session',
    resultPath: env.SAP_BROWSER_RESULT_PATH,
  };
}

async function loadFlow(filename) {
  const root = await realpath(dirname(fileURLToPath(import.meta.url)));
  const target = await realpath(resolve(root, filename));
  const path = relative(root, target);
  if (path.startsWith('..') || !path.endsWith('.mjs')) {
    throw new SetupError('Flow must be an .mjs module inside hack/sap-browser.');
  }
  return import(pathToFileURL(target).href);
}

export async function main(env = process.env) {
  const options = pipelineOptions(env);
  const metadata = { mode: options.mode, pipelineRun: options.pipelineRun, clusterName: options.clusterName };
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(new SetupError('Browser session time limit reached.')), options.sessionMinutes * 60000);
  const interrupted = () => abort.abort(new SetupError('Browser session interrupted.'));
  process.once('SIGTERM', interrupted);
  process.once('SIGINT', interrupted);
  let browser;
  let closing = false;
  const stopped = new Promise((_, reject) => {
    abort.signal.addEventListener('abort', () => {
      reject(abort.signal.reason);
      void browser?.close();
    }, { once: true });
  });
  // The deadline covers input loading, login, automation and the final inspection.
  try {
    await Promise.race([stopped, (async () => {
      await writeStatus(options.directory, 'loading-inputs', metadata);
      const inputs = await loadInputs(inClusterReader(options.namespace), options.pipelineRun, {
        expectedRunUID: options.pipelineRunUID, expectedClusterName: options.clusterName,
      });
      abort.signal.throwIfAborted();
      const flow = options.mode === 'run' ? await loadFlow(options.flow) : null;
      browser = await chromium.launch({ headless: false, args: ['--window-size=1440,900'] });
      browser.on('disconnected', () => { if (!closing) interrupted(); });
      const context = await browser.newContext({ viewport: null });
      context.setDefaultTimeout(30000);
      const page = await context.newPage();
      const waitForLogin = async () => {
        await page.waitForURL((url) => url.origin === new URL(options.url).origin, {
          timeout: options.loginMinutes * 60000,
        });
        await page.getByRole('heading', { name: 'Edge Nodes', exact: true }).waitFor({
          state: 'visible', timeout: options.loginMinutes * 60000,
        });
        if (new URL(page.url()).origin !== new URL(options.url).origin) throw new SetupError('Unexpected SAP tenant.');
      };
      await withPrivateFiles(inputs, async (files) => {
        await managedSession({
          directory: options.directory, metadata, signal: abort.signal, resultPath: options.resultPath,
          work: async () => {
            await writeStatus(options.directory, 'waiting-for-login', metadata);
            console.log('Open the forwarded noVNC page, then complete SAP login/MFA in Chromium.');
            await page.goto(options.url, { waitUntil: 'domcontentloaded' });
            await waitForLogin();
            await writeStatus(options.directory, 'automating', metadata);
            let outcome;
            if (options.mode === 'review-registration') {
              await reviewRegistration(page, {
                ...inputs, highAvailability: options.highAvailability,
                onStep: async (stage) => {
                  metadata.stage = stage;
                  await writeStatus(options.directory, 'automating', metadata);
                  console.log(`Registration step: ${stage}`);
                },
              });
              console.log('Configuration Review reached. Nothing has been submitted; EIC readiness is not verified.');
              outcome = 'registration-reviewed';
            } else if (options.mode === 'inspect') {
              console.log('Inspector is open after login. Resume Inspector when the walkthrough is finished.');
              console.log('Recordings can contain entered credentials; keep them private.');
              await page.pause();
              outcome = 'inspection-finished';
            } else {
              outcome = await executeFlow(flow, { page, context, inputs, files, waitForLogin });
              console.log('Flow readiness checks passed.');
            }
            console.log('Use the session finish command when done. The manual pipeline approval remains in place.');
            return outcome;
          },
        });
      }, options.directory);
    })()]);
  } finally {
    closing = true;
    clearTimeout(timer);
    process.removeListener('SIGTERM', interrupted);
    process.removeListener('SIGINT', interrupted);
    await browser?.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().then(() => { process.exitCode = 0; }).catch((error) => {
    console.error('SAP browser task stopped.');
    if (error instanceof SetupError) console.error(error.message);
    // No Playwright stacks/call logs: fill() errors can include credentials.
    process.exitCode = 1;
  });
}
