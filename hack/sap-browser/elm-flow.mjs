// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { SetupError } from './inputs.mjs';
import { ARTIFACTS } from './is-pages.mjs';
import { uploadBundle } from './s3.mjs';

const VALID_STATES = ['absent', 'added', 'initialized', 'eic-deployed'];

function normalizeId(id) {
  return String(id).trim().toLowerCase();
}

export async function withLogin(page, steps, fn, { waitForLogin, reopen }) {
  try {
    return await fn();
  } catch (error) {
    if (await steps.isSessionExpired(page)) {
      await waitForLogin();
      await reopen();
      return await fn();
    }
    throw error;
  }
}

export async function runIntegrationFlow({ page, steps, isSteps, cells, waitForLogin, pollMs, timeoutMs }) {
  // Navigate to Integration Suite home page
  const origin = new URL(page.url()).origin;
  await page.goto(`${origin}/shell/home`);

  const reopenIS = async () => {
    await page.goto(`${origin}/shell/home`);
  };

  // Deploy keystore to all runtimes
  const runtimes = cells.map(cell => cell.deployment);
  await withLogin(page, steps, () => isSteps.deployKeystore(page, { runtimes }), { waitForLogin, reopen: reopenIS });

  // Per cell: wait for runtime ready, deploy artifacts, wait for all started
  for (const cell of cells) {
    // Wait for runtime to be ready
    const startTime = Date.now();
    while (!(await withLogin(page, steps, () => isSteps.runtimeReady(page, { deployment: cell.deployment }), { waitForLogin, reopen: reopenIS }))) {
      if (Date.now() - startTime > timeoutMs) {
        throw new SetupError(`Runtime ${cell.deployment} did not become ready within timeout.`);
      }
      await new Promise(resolve => setTimeout(resolve, pollMs));
    }

    // Deploy all artifacts for this cell
    for (const { pkg, artifact } of ARTIFACTS) {
      await withLogin(page, steps, () => isSteps.deployArtifact(page, { pkg, artifact, deployment: cell.deployment }), { waitForLogin, reopen: reopenIS });
    }
  }

  // Wait for all artifacts to be started
  for (const cell of cells) {
    const startTime = Date.now();
    let allStarted = false;
    while (!allStarted) {
      if (Date.now() - startTime > timeoutMs) {
        throw new SetupError(`Artifacts for ${cell.deployment} did not all start within timeout.`);
      }
      const states = await withLogin(page, steps, () => isSteps.artifactStates(page, { deployment: cell.deployment }), { waitForLogin, reopen: reopenIS });
      allStarted = ARTIFACTS.every(({ artifact }) => states[artifact] === 'Started');
      if (!allStarted) {
        await new Promise(resolve => setTimeout(resolve, pollMs));
      }
    }
  }
}

export async function runDeployFlow(ctx) {
  const { page, steps, isSteps, inputs, clusterEdgeNodeId, leftoverPolicy, loadCells, s3, s3Prefix, dir, waitForTask, meshTask, loadKubeconfig, fetchElm, elmInit, password, recordNode, readNodeRecord, waitForLogin, log, pollMs, timeoutMs } = ctx;
  const { clusterName } = inputs;

  const reopen = async () => {
    await steps.openEdgeNode(page, clusterName);
  };

  // Step 1: Get edge node state and validate
  let state = await withLogin(page, steps, () => steps.edgeNodeState(page, clusterName), { waitForLogin, reopen });

  if (!VALID_STATES.includes(state)) {
    throw new SetupError(`Edge Node has unrecognised state: ${state}. Cannot proceed safely.`);
  }

  // Step 2: Validate leftover policy
  if (!['delete', 'hand-over'].includes(leftoverPolicy)) {
    throw new SetupError(`Unknown leftoverPolicy: ${leftoverPolicy}`);
  }

  // Step 3: Handle leftover nodes based on policy
  if (state !== 'absent') {
    if (leftoverPolicy === 'delete') {
      // ROKS behavior: delete if IDs don't match or unknown
      const existingId = await withLogin(page, steps, () => steps.edgeNodeId(page, clusterName), { waitForLogin, reopen });

      if (clusterEdgeNodeId === 'unknown') {
        throw new SetupError(`Cannot verify that the existing Edge Node ${clusterName} belongs to this cluster; not deleting it. Continue manually.`);
      }

      if (!clusterEdgeNodeId || normalizeId(existingId) !== normalizeId(clusterEdgeNodeId)) {
        log(`Leftover Edge Node detected (existing ID: ${existingId}, cluster ID: ${clusterEdgeNodeId}), deleting...`);
        await withLogin(page, steps, () => steps.removeEdgeNode(page, { clusterName }), { waitForLogin, reopen });
        state = 'absent';
      }
    } else if (leftoverPolicy === 'hand-over') {
      // HCP behavior: only resume if node matches record
      const record = await readNodeRecord();
      const existingElmId = await withLogin(page, steps, () => steps.edgeNodeElmId(page), { waitForLogin, reopen });

      if (!record || normalizeId(record.elmId) !== normalizeId(existingElmId)) {
        throw new SetupError(`Edge Node ${clusterName} exists but does not match the ownership record. Cannot proceed safely.`);
      }
    }
  }

  // Step 4: Proxy check - hand over if proxy is configured and node is absent
  if (inputs.proxy && state === 'absent') {
    throw new SetupError('HTTP proxy runs: add the Edge Node by hand');
  }

  // Step 5: Add edge node if absent
  if (state === 'absent') {
    await withLogin(page, steps, () => steps.addEdgeNode(page, { clusterName, registry: inputs.registry, highAvailability: inputs.highAvailability }), { waitForLogin, reopen });
    state = 'added';

    // Record the node ownership
    const elmId = await withLogin(page, steps, () => steps.edgeNodeElmId(page), { waitForLogin, reopen });
    await recordNode({ name: clusterName, elmId });
  }

  // Step 6: Download ELM zip and upload to S3
  const elmZipPath = await withLogin(page, steps, () => steps.downloadElmZip(page, { clusterName, dir }), { waitForLogin, reopen });
  await uploadBundle(s3, { file: elmZipPath, s3Prefix, component: 'elm' });

  // Step 7: Wait for pipeline task
  await waitForTask('generate-sa-based-kubeconfig');

  // Step 8: Set up cloud connector if needed (state is absent or added)
  if (state === 'absent' || state === 'added') {
    const kubeconfigContent = await loadKubeconfig();
    const kubeconfigFile = join(dir, 'edgelm-kubeconfig.yaml');
    try {
      await rm(kubeconfigFile, { force: true });
    } catch {}
    await writeFile(kubeconfigFile, kubeconfigContent, { mode: 0o600, flag: 'wx' });

    const contextFile = await withLogin(page, steps, () => steps.setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }), { waitForLogin, reopen });

    const elmPath = await fetchElm(dir);

    await elmInit({ elmPath, contextFile, password, cwd: dir, log });
    state = 'initialized';
  }

  // Step 9: Load cells
  const cells = await loadCells();

  // Step 10: Deploy EIC for each cell with idempotency (R5)
  for (const cell of cells) {
    // R2: Check if cell has eic property
    if (!cell.eic) {
      throw new SetupError(`EIC form values for ${cell.component} are not mapped yet; deploy EIC by hand`);
    }

    // R5: Check deployment status for idempotency
    const status = await withLogin(page, steps, () => steps.eicDeploymentStatus(page, { clusterName, deployment: cell.deployment }), { waitForLogin, reopen });

    if (!status) {
      // null: deploy from scratch
      await withLogin(page, steps, () => steps.deployEic(page, { clusterName, cell }), { waitForLogin, reopen });
    } else if (status.operation === 'Initial' || status.operation === 'Prepared') {
      // Initial/Prepared: skip deployEic, will download zip and resume
    } else if (status.operation === 'Successful') {
      // Successful: skip deployEic and zip/resume (handled below)
    } else {
      // Unknown operation: hand over
      throw new SetupError(`EIC deployment ${cell.deployment} has unknown operation ${status.operation}; continue manually`);
    }
  }

  // Step 11: Download EIC zip and upload to S3 for each cell (skip if Successful)
  for (const cell of cells) {
    const status = await withLogin(page, steps, () => steps.eicDeploymentStatus(page, { clusterName, deployment: cell.deployment }), { waitForLogin, reopen });

    if (!status || status.operation !== 'Successful') {
      const eicZipPath = await withLogin(page, steps, () => steps.downloadEicZip(page, { clusterName, deployment: cell.deployment, dir }), { waitForLogin, reopen });
      await uploadBundle(s3, { file: eicZipPath, s3Prefix, component: cell.component });
    }
  }

  // Step 12: Wait for mesh task
  await waitForTask(meshTask);

  // Step 13: Resume EIC deployment for each cell (skip if Successful)
  for (const cell of cells) {
    const status = await withLogin(page, steps, () => steps.eicDeploymentStatus(page, { clusterName, deployment: cell.deployment }), { waitForLogin, reopen });

    if (!status || status.operation !== 'Successful') {
      await withLogin(page, steps, () => steps.resumeEicDeployment(page, { clusterName, deployment: cell.deployment }), { waitForLogin, reopen });
    }
  }

  // Step 14: Poll eicDeploymentStatus until all cells are Successful (sequential, reload page each round)
  const startTime = Date.now();
  let allSuccessful = false;
  while (!allSuccessful) {
    if (Date.now() - startTime > timeoutMs) {
      const pending = cells.map(cell => cell.deployment).join(', ');
      throw new SetupError(`EIC deployment status did not reach Successful for all cells (${pending}) within timeout.`);
    }

    // Reload the node page before polling statuses
    await withLogin(page, steps, reopen, { waitForLogin, reopen });

    // Poll each cell sequentially
    const statuses = [];
    for (const cell of cells) {
      const status = await withLogin(page, steps, () => steps.eicDeploymentStatus(page, { clusterName, deployment: cell.deployment }), { waitForLogin, reopen });
      statuses.push(status);
    }

    allSuccessful = statuses.every(status => status && status.operation === 'Successful');

    if (!allSuccessful) {
      await new Promise(resolve => setTimeout(resolve, pollMs));
    }
  }

  // Step 15: Run integration flow
  await runIntegrationFlow({ page, steps, isSteps, cells, waitForLogin, pollMs, timeoutMs });

  return 'deployed';
}

export async function runTeardownFlow({ page, steps, clusterName, log }) {
  const state = await steps.edgeNodeState(page, clusterName);

  if (!VALID_STATES.includes(state)) {
    throw new SetupError(`Edge Node has unrecognised state: ${state}. Cannot proceed safely.`);
  }

  if (state === 'absent') {
    return 'nothing-to-delete';
  }

  await steps.removeEdgeNode(page, { clusterName });
  return 'edge-node-deleted';
}
