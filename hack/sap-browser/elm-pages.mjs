// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { randomBytes } from 'node:crypto';
import { basename, join } from 'node:path';
import { SetupError } from './inputs.mjs';
import { fillRegistration } from './registration.mjs';

function notMapped(method) {
  throw new SetupError(`ELM screen step not mapped yet: ${method}. Record it with sapBrowserMode inspect.`);
}

export const elmPages = {
  async edgeNodeState(page, clusterName) {
    // Check if we're on the list page
    const table = page.getByRole('grid', { name: 'All Edge Nodes', exact: true });
    const tableCount = await table.count();

    if (tableCount > 0) {
      // We're on the list page - check if node exists
      const nodeCount = await table.getByText(clusterName, { exact: true }).count();
      if (nodeCount === 0) {
        return 'absent';
      }
      // Node exists in list but we need to open it to check status
      // This shouldn't happen in normal flow, but return 'added' as safe default
      return 'added';
    }

    // We're on a node page - check for Deployments tab (initialized state)
    const deploymentsTab = page.getByRole('tab', { name: 'Deployments', exact: true });
    if (await deploymentsTab.count() > 0) {
      return 'initialized';
    }

    // Check status text
    const statusElements = await page.locator('div').filter({ hasText: /^Status: / }).all();
    if (statusElements.length > 0) {
      const statusText = await statusElements[0].textContent();
      const status = statusText.replace(/^Status: /, '').trim();
      if (status === 'Not Initialized') {
        return 'added';
      }
      return status;
    }

    return 'added';
  },

  async edgeNodeElmId(page) {
    const url = page.url();
    const match = url.match(/#\/clusters\/(\d+)/);
    if (!match) {
      throw new SetupError('Cannot extract ELM node ID from URL.');
    }
    return match[1];
  },

  async openEdgeNode(page, clusterName) {
    const table = page.getByRole('grid', { name: 'All Edge Nodes', exact: true });
    await table.getByText(clusterName, { exact: true }).click();
  },

  async addEdgeNode(page, { clusterName, registry, highAvailability = false }) {
    await fillRegistration(page, { clusterName, highAvailability });

    // Go back to Step 2 if registry is provided
    if (registry) {
      await page.getByRole('button', { name: 'Step 2', exact: true }).click();
      await page.getByRole('checkbox', { name: 'Replicate Container Images', exact: true }).check();
      await page.getByRole('textbox', { name: 'Local Container Registry URL', exact: true }).fill(registry.url);
      await page.getByRole('textbox', { name: 'Username', exact: true }).fill(registry.username);
      await page.getByRole('textbox', { name: 'Password', exact: true }).fill(registry.password);
      await page.getByRole('checkbox', { name: 'Non-Trusted Certificate', exact: true }).check();
      await page.getByRole('button', { name: 'Certificate with Public Key', exact: true }).setInputFiles(registry.caCertificateFile);
      await page.getByRole('button', { name: 'Step 3', exact: true }).click();
      await page.getByRole('button', { name: 'Review', exact: true }).click();
    }

    await page.getByRole('button', { name: 'Add Edge Node', exact: true }).click();
  },

  async downloadElmZip(page, { clusterName, dir }) {
    await page.getByRole('button', { name: 'Download Kubernetes Resources', exact: true }).click();
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByRole('button', { name: 'Download', description: 'Default Action' }).click(),
    ]);
    const filename = download.suggestedFilename();
    const path = join(dir, basename(filename));
    await download.saveAs(path);
    await page.getByRole('checkbox', { name: 'I confirm that I have downloaded and applied resources.', exact: true }).check();
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();
    return path;
  },

  async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
    await page.getByLabel('Browse or drop a file', { exact: true }).getByTitle('Browse or drop a file', { exact: true }).click();
    await page.getByRole('button', { name: 'Kubeconfig File', exact: true }).setInputFiles(kubeconfigFile);
    await page.getByRole('textbox', { name: 'Context Password', exact: true }).fill(password);
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByRole('button', { name: 'Download Bootstrapping File', exact: true }).click(),
    ]);
    const filename = download.suggestedFilename();
    const path = join(dir, basename(filename));
    await download.saveAs(path);
    return path;
  },

  async deployEic(page, { clusterName, inputs, files }) {
    notMapped('deployEic');
  },

  async downloadEicZip(page, { clusterName, dir }) {
    notMapped('downloadEicZip');
  },

  async finishEicDeployment(page, { clusterName }) {
    notMapped('finishEicDeployment');
  },

  async deleteEdgeNode(page, { clusterName }) {
    notMapped('deleteEdgeNode');
  },

  async isSessionExpired(page) {
    const url = page.url();
    if (!url.includes('#/errorPage')) {
      return false;
    }
    return page.getByRole('button', { name: 'Sign in again', exact: true }).isVisible();
  },
};

export function contextPassword() {
  return randomBytes(24).toString('base64url');
}
