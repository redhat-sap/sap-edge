// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0
// cspell:words PWDEBUG domcontentloaded

import { parseArgs } from 'node:util';
import { createInterface } from 'node:readline/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { kubernetesReader, loadInputs, readPreparedInputs, SetupError, withPrivateFiles, writePreparedInputs } from './inputs.mjs';
import { reviewRegistration } from './registration.mjs';

const help = `SAP browser helper (Node.js 20+)

  npm run sap:browser -- inspect --url <ELM-URL>
  npm run sap:browser -- review-registration --url <ELM-URL> --cluster <NAME>
  node hack/sap-browser/cli.mjs prepare-inputs --context <PIPELINE-CONTEXT> \\
    --namespace <PIPELINE-NAMESPACE> --pipeline-run <NAME> --output <NEW-DIRECTORY>
  npm run sap:browser -- review-registration --url <ELM-URL> --inputs <INPUTS.json>
  npm run sap:browser -- review-registration --url <ELM-URL> \\
    --context <PIPELINE-CONTEXT> --namespace <PIPELINE-NAMESPACE> --pipeline-run <NAME>
  npm run sap:browser -- run --url <ELM-URL> --flow <REVIEWED-FLOW.mjs> \\
    --context <PIPELINE-CONTEXT> --namespace <PIPELINE-NAMESPACE> --pipeline-run <NAME>

inspect              Log in manually, then open the Playwright Inspector/recorder.
prepare-inputs       Inside the SAP network, collect credentials into a private local file.
review-registration  Read this run's Secrets and fill the ELM wizard through review.
run                  Execute a local, reviewed flow exporting run() and verify().

Options:
  --cli <oc|kubectl>    Kubernetes CLI (default: oc)
  --channel <chrome>   Use installed Google Chrome instead of bundled Chromium
  --ha                 Enable ELM High Availability Mode for registration review
  --cluster <NAME>      Review only: fill a name without reading Kubernetes Secrets
  --inputs <FILE>       Use prepared inputs; do not contact Kubernetes
  --output <DIRECTORY>  New directory for prepare-inputs; contains credentials
  --login-minutes <n>   Time allowed for interactive login (default: 15)
  --help               Show this help

Use the direct ELM URL, not the BTP cockpit. The browser is visible and temporary.
No password recording, saved login state, screenshots, traces, or pipeline approval
is enabled automatically. Initialization, EIC and iFlow deployment require a flow
mapped to your tenant; review-registration does not complete those operations.
`;

export function optionsFor(args) {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: {
    url: { type: 'string' }, context: { type: 'string' }, namespace: { type: 'string' },
    'pipeline-run': { type: 'string' }, cluster: { type: 'string' }, flow: { type: 'string' },
    inputs: { type: 'string' }, output: { type: 'string' },
    cli: { type: 'string', default: 'oc' }, channel: { type: 'string' },
    ha: { type: 'boolean', default: false }, help: { type: 'boolean', default: false },
    'login-minutes': { type: 'string', default: '15' },
  } });
  if (values.help) return { help: true };
  const mode = positionals[0];
  if (positionals.length !== 1 || !['inspect', 'prepare-inputs', 'review-registration', 'run'].includes(mode)) {
    throw new SetupError('Choose inspect, prepare-inputs, review-registration, or run. Use --help for examples.');
  }
  let url;
  if (mode === 'prepare-inputs') {
    if (!values.output || values.url || values.cluster || values.inputs) {
      throw new SetupError('prepare-inputs requires --output and pipeline options, without --url, --cluster or --inputs.');
    }
  } else {
    if (values.output) throw new SetupError('--output is only valid for prepare-inputs.');
    try { url = new URL(values.url); } catch { throw new SetupError('--url must be an absolute ELM HTTPS URL.'); }
    if (url.protocol !== 'https:' || url.username || url.password) throw new SetupError('Use an HTTPS URL without embedded credentials.');
  }
  if (values.inputs && (!['review-registration', 'run'].includes(mode) || values.cluster || values.context || values.namespace || values['pipeline-run'])) {
    throw new SetupError('--inputs is an alternative to cluster/pipeline options in review-registration or run mode.');
  }
  if (!['oc', 'kubectl'].includes(values.cli)) throw new SetupError('--cli must be oc or kubectl.');
  if (values.channel && values.channel !== 'chrome') throw new SetupError('--channel must be chrome when supplied.');
  const loginMinutes = Number(values['login-minutes']);
  if (!Number.isFinite(loginMinutes) || loginMinutes < 1 || loginMinutes > 120) throw new SetupError('--login-minutes must be between 1 and 120.');
  if (values.cluster) {
    if (mode !== 'review-registration' || values.context || values.namespace || values['pipeline-run']) {
      throw new SetupError('--cluster is a review-only alternative to --context, --namespace and --pipeline-run.');
    }
    if (!/^[a-z](?:[a-z0-9-]*[a-z0-9])?$/.test(values.cluster) || values.cluster.length > 63) {
      throw new SetupError('--cluster must be a valid lowercase cluster name of at most 63 characters.');
    }
  }
  if (mode !== 'inspect' && !values.cluster && !values.inputs && (!values.context || !values.namespace || !values['pipeline-run'])) {
    throw new SetupError('--context, --namespace and --pipeline-run are required for this mode.');
  }
  for (const name of ['namespace', 'pipeline-run']) {
    if (values[name] && !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(values[name])) {
      throw new SetupError(`--${name} must be a Kubernetes resource name.`);
    }
  }
  if (mode === 'run' && !values.flow) throw new SetupError('run requires --flow pointing to a reviewed local module.');
  if (mode !== 'run' && values.flow) throw new SetupError('--flow is only valid in run mode.');
  return { ...values, mode, url: url?.href, loginMinutes };
}

async function browserSession(options, inputs, files) {
  const { chromium } = await import('playwright');
  // Never enable PWDEBUG: it starts recording before the user's login is complete.
  if (process.env.PWDEBUG || process.env.DEBUG?.includes('pw:')) {
    throw new SetupError('Unset PWDEBUG and Playwright DEBUG logging before handling credentials.');
  }
  const flow = options.mode === 'run' ? await import(pathToFileURL(resolve(options.flow)).href) : null;
  if (flow && (typeof flow.run !== 'function' || typeof flow.verify !== 'function')) {
    throw new SetupError('A flow must export async run() and verify(); verify must return true only after readiness checks.');
  }
  const browser = await chromium.launch({ headless: false, channel: options.channel });
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  const abort = new AbortController();
  browser.once('disconnected', () => { abort.abort(); terminal.close(); });
  const interrupted = () => { void browser.close(); terminal.close(); };
  process.once('SIGINT', interrupted);
  process.once('SIGTERM', interrupted);
  try {
    const context = await browser.newContext({ viewport: null });
    context.setDefaultTimeout(30000);
    const page = await context.newPage();
    await page.goto(options.url, { waitUntil: 'domcontentloaded' });
    console.log('Complete SAP login/MFA in the browser. Open Edge Nodes in this same tab.');
    const waitForLogin = async () => {
      await page.waitForURL((url) => url.origin === new URL(options.url).origin, {
        timeout: options.loginMinutes * 60000,
      });
      await page.getByRole('heading', { name: 'Edge Nodes', exact: true }).waitFor({
        state: 'visible', timeout: options.loginMinutes * 60000,
      });
      if (new URL(page.url()).origin !== new URL(options.url).origin) throw new SetupError('Unexpected tenant after login.');
    };
    await waitForLogin();
    if (options.mode === 'inspect') {
      console.log('Login complete. Inspector opens now; use Record for the setup steps.');
      console.log('Recordings can include entered values. Keep raw recordings private and replace secrets with inputs before committing.');
      await page.pause();
    } else if (options.mode === 'review-registration') {
      await reviewRegistration(page, { ...inputs, highAvailability: options.ha });
      console.log(`Registration review ready for ${inputs.clusterName}. Nothing has been submitted.`);
      console.log('Review the browser. Initialization and EIC/iFlow deployment still need a tenant-specific flow.');
      if (files) {
        console.log('Files for this session only:');
        for (const [key, filename] of Object.entries(files)) console.log(`  ${key}: ${filename}`);
      } else {
        console.log('Name-only preview: Kubernetes readiness and credentials have not been checked.');
      }
    } else {
      // Flow modules are trusted local code and receive credentials. Never load a downloaded recording blindly.
      const args = { page, context, inputs, files, waitForLogin };
      await flow.run(args);
      if (await flow.verify(args) !== true) throw new SetupError('The flow did not verify deployment readiness.');
      console.log('Flow readiness checks passed. Review the existing Tekton approval gate to continue tests.');
    }
    await terminal.question('Press Enter to close this browser and remove temporary files. ', { signal: abort.signal });
  } finally {
    terminal.close();
    process.removeListener('SIGINT', interrupted);
    process.removeListener('SIGTERM', interrupted);
    await browser.close();
  }
}

export async function main(args) {
  const options = optionsFor(args);
  if (options.help) { console.log(help); return; }
  if (options.mode === 'prepare-inputs') {
    const inputs = await loadInputs(kubernetesReader(options), options['pipeline-run']);
    const filename = await writePreparedInputs(inputs, options.output);
    console.log(`Prepared credential file: ${filename}`);
    console.log('The file remains on this machine. Run the browser helper with --inputs when ready.');
    return;
  }
  if (!process.stdin.isTTY) throw new SetupError('Run this helper in an interactive terminal for SAP login.');
  if (options.mode === 'inspect') return browserSession(options);
  if (options.cluster) return browserSession(options, { clusterName: options.cluster });
  let inputs;
  if (options.inputs) {
    const prepared = await readPreparedInputs(options.inputs);
    inputs = prepared.inputs;
    console.log(`Using inputs prepared at ${prepared.preparedAt}; no live Kubernetes check will run.`);
  } else {
    inputs = await loadInputs(kubernetesReader(options), options['pipeline-run']);
  }
  console.log(`PipelineRun: ${inputs.pipelineRun}; cluster: ${inputs.clusterName}; datastore: ${inputs.datastore.type}`);
  await withPrivateFiles(inputs, (files) => browserSession(options, inputs, files));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch((error) => {
    // Playwright errors can echo fill() values. Do not dump call logs or stacks.
    console.error('SAP browser helper stopped.');
    if (error instanceof SetupError) {
      console.error(String(error.message).split('\n')[0]);
    }
    console.error('The pipeline approval gate was not changed. Check the current step before retrying.');
    process.exitCode = 1;
  });
}
