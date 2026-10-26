// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { SetupError } from './inputs.mjs';
import { uploadBundle } from './s3.mjs';

const VALID_STATES = ['absent', 'added', 'initialized', 'eic-deployed'];

function normalizeId(id) {
  return String(id).trim().toLowerCase();
}

export async function runDeployFlow(ctx) {
  const { page, steps, inputs, clusterEdgeNodeId, s3, s3Prefix, dir, waitForTask, loadKubeconfig, fetchElm, elmInit, password, log } = ctx;
  const { clusterName } = inputs;

  // Step 1: Get edge node state and validate
  let state = await steps.edgeNodeState(page, clusterName);

  if (!VALID_STATES.includes(state)) {
    throw new SetupError(`Edge Node has unrecognised state: ${state}. Cannot proceed safely.`);
  }

  // Step 2: Handle leftover nodes (check if existing node belongs to this cluster)
  if (state !== 'absent') {
    // Get the existing edge node ID
    const existingId = await steps.edgeNodeId(page, clusterName);

    // If clusterEdgeNodeId is 'unknown' and a node exists, we cannot verify ownership
    if (clusterEdgeNodeId === 'unknown') {
      throw new SetupError(`Cannot verify that the existing Edge Node ${clusterName} belongs to this cluster; not deleting it. Continue manually.`);
    }

    // If cluster ID is empty or IDs don't match (normalized), delete the leftover node
    if (!clusterEdgeNodeId || normalizeId(existingId) !== normalizeId(clusterEdgeNodeId)) {
      log(`Leftover Edge Node detected (existing ID: ${existingId}, cluster ID: ${clusterEdgeNodeId}), deleting...`);
      await steps.deleteEdgeNode(page, { clusterName });
      state = 'absent';
    }
  }

  // Step 3: Add edge node if absent
  if (state === 'absent') {
    await steps.addEdgeNode(page, { clusterName, registry: inputs.registry });
    state = 'added';
  }

  // Step 4: Download ELM zip and upload to S3
  const elmZipPath = await steps.downloadElmZip(page, { clusterName, dir });
  await uploadBundle(s3, { file: elmZipPath, s3Prefix, component: 'elm' });

  // Step 5: Wait for pipeline task
  await waitForTask('generate-sa-based-kubeconfig');

  // Step 6: Set up cloud connector if needed (state is absent or added)
  if (state === 'absent' || state === 'added') {
    const kubeconfigContent = await loadKubeconfig();
    const kubeconfigFile = join(dir, 'edgelm-kubeconfig.yaml');
    try {
      await rm(kubeconfigFile, { force: true });
    } catch {}
    await writeFile(kubeconfigFile, kubeconfigContent, { mode: 0o600, flag: 'wx' });

    const contextFile = await steps.setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir });

    const elmPath = await fetchElm(dir);

    await elmInit({ elmPath, contextFile, password, cwd: dir });
    state = 'initialized';
  }

  // Step 7: Deploy EIC if not already deployed
  if (state !== 'eic-deployed') {
    // Write CA cert files
    const postgresCAFile = join(dir, 'postgres-ca.crt');
    const redisCAFile = join(dir, 'redis-ca.crt');
    try {
      await rm(postgresCAFile, { force: true });
      await rm(redisCAFile, { force: true });
    } catch {}
    await writeFile(postgresCAFile, inputs.attachments.postgresCA, { mode: 0o600, flag: 'wx' });
    await writeFile(redisCAFile, inputs.attachments.redisCA, { mode: 0o600, flag: 'wx' });

    const files = {
      postgresCA: postgresCAFile,
      redisCA: redisCAFile,
    };

    await steps.deployEic(page, { clusterName, inputs, files });
  }

  // Step 8: Download EIC zip and upload to S3
  const eicZipPath = await steps.downloadEicZip(page, { clusterName, dir });
  await uploadBundle(s3, { file: eicZipPath, s3Prefix, component: 'edge-icell' });

  // Step 9: Wait for configure-mesh-eic
  await waitForTask('configure-mesh-eic');

  // Step 10: Finish EIC deployment
  await steps.finishEicDeployment(page, { clusterName });

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

  await steps.deleteEdgeNode(page, { clusterName });
  return 'edge-node-deleted';
}
