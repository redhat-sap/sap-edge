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
      // Node exists in list - open it to check its actual state
      await this.openEdgeNode(page, clusterName);
      // Fall through to check the node page
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

  edgeNodeId(page, clusterName) {
    notMapped('edgeNodeId');
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

  async downloadElmCli(page, { dir, timeoutMs = 60000 }) {
    // Click Linux tab to show the download link
    await page.getByRole('button', { name: 'Linux', exact: true }).click();

    // Use context-level waitForEvent to handle popups (SAP Download Center)
    try {
      const downloadPromise = page.context().waitForEvent('download', { timeout: timeoutMs });

      // Find and click the download link (starts with "Download ELMB00_")
      const downloadLink = page.locator('a[download^="ELMB00_"]').first();
      await downloadLink.click();

      const download = await downloadPromise;
      const filename = download.suggestedFilename();
      const path = join(dir, filename);
      await download.saveAs(path);
      return path;
    } catch (error) {
      if (error.message?.includes('Timeout')) {
        throw new SetupError('ELM CLI download timed out. Upload the Linux x86_64 elm binary to tools/elm/ in the bucket.');
      }
      throw error;
    }
  },

  async deployEic(page, { clusterName, cell }) {
    await page.getByRole('button', { name: 'Deploy Solution', exact: true }).click();

    // Handle solution: if provided and not empty, check if it's offered
    if (cell.eic.solution) {
      const solutionCombo = page.locator('[id$="--solutionsList-arrow"]');
      await solutionCombo.click();
      // Look for the solution in the dropdown list, not in the selected item
      const solutionList = solutionCombo.locator('.list');
      const solutionOption = solutionList.getByText(cell.eic.solution, { exact: true });
      if (await solutionOption.count() === 0) {
        throw new SetupError(`Solution ${cell.eic.solution} is not offered by ELM.`);
      }
      await solutionOption.click();
    }
    // If solution is empty, keep the preselected solution

    // Fill deployment name
    await page.getByRole('textbox', { name: 'Deployment Name', exact: true }).fill(cell.deployment);

    // Handle version: if provided and not empty, check if it's offered
    if (cell.eic.version) {
      const versionCombo = page.locator('[id$="--versionCombo-arrow"]');
      await versionCombo.click();
      // Look for the version in the dropdown list, not in the selected item
      const versionList = versionCombo.locator('.list');
      const versionOption = versionList.getByText(cell.eic.version, { exact: true });
      if (await versionOption.count() === 0) {
        throw new SetupError(`EIC version ${cell.eic.version} is not offered by ELM.`);
      }
      await versionOption.click();
    }
    // If version is empty, keep the preselected version

    // Step 1: Namespaces
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();

    const namespacesForm = page.locator('[id$="--namespacesForm--Form--Grid"]');
    await namespacesForm.getByRole('textbox', { name: 'Edge Integration Cell (main namespace)', exact: true }).fill(cell.eic.namespaces.main);
    await namespacesForm.getByRole('textbox', { name: 'Edge Security Artifact Secrets', exact: true }).fill(cell.eic.namespaces.secrets);
    await namespacesForm.getByRole('textbox', { name: 'Edge Local Authorization', exact: true }).fill(cell.eic.namespaces.ela);
    await namespacesForm.getByRole('textbox', { name: 'Default Virtual Host', exact: true }).fill(cell.eic.virtualHost);
    await namespacesForm.getByRole('textbox', { name: 'Default Virtual Host Key Alias', exact: true }).fill(cell.eic.keyAlias);

    // Enable shared file system
    const sharedFsCheckbox = namespacesForm.locator('input[type="checkbox"]').first();
    await sharedFsCheckbox.check();
    await namespacesForm.getByRole('textbox', { name: 'Shared File System Storage', exact: true }).fill(cell.eic.sharedFsStorageClass);

    // Step 2: Services (click Next Step twice to skip step 2)
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();

    await page.getByRole('textbox', { name: 'Deployment Name', exact: true }).fill(cell.eic.servicesDeployment);
    await page.getByRole('textbox', { name: 'Edge Integration Cell', exact: true }).fill(cell.eic.namespaces.services);

    // PostgreSQL fields
    await page.getByRole('textbox', { name: 'PostgreSQL Hostname', exact: true }).fill(cell.services.postgres.host);
    await page.getByRole('textbox', { name: 'PostgreSQL Port', exact: true }).fill(cell.services.postgres.port);
    await page.getByRole('textbox', { name: 'PostgreSQL DB Name', exact: true }).fill(cell.services.postgres.database);
    await page.getByRole('textbox', { name: 'PostgreSQL Username', exact: true }).fill(cell.services.postgres.username);
    await page.getByRole('textbox', { name: 'PostgreSQL Password', exact: true }).fill(cell.services.postgres.password);

    // PostgreSQL CA file
    const pgCaButton = page.getByRole('button', { name: 'Browse or drop a file', exact: true }).filter({ has: page.locator('[aria-label*="PostgreSQL"]') }).or(page.getByRole('button', { name: 'Browse or drop a file', exact: true }).first());
    await pgCaButton.setInputFiles(cell.files.postgresCA);

    // Redis/Valkey fields
    const datastoreType = cell.services.datastore.type;
    const isRedis = datastoreType === 'redis';
    const prefix = isRedis ? 'Redis' : 'Valkey';

    await page.getByRole('textbox', { name: `${prefix} Addresses`, exact: true }).fill(cell.services.datastore.address);
    await page.getByRole('textbox', { name: `${prefix} Password`, exact: true }).fill(cell.services.datastore.password);

    // CA file for Redis/Valkey - find the last "Browse or drop a file" button
    const datastoreCaButton = page.getByRole('button', { name: 'Browse or drop a file', exact: true }).last();
    await datastoreCaButton.setInputFiles(cell.files.redisCA);

    await page.getByRole('textbox', { name: `${prefix} Server Name`, exact: true }).fill(cell.services.datastore.serverName);

    // Step 3: Gateways
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();

    await page.getByRole('textbox', { name: 'Deployment Name', exact: true }).fill(cell.eic.gatewaysDeployment);
    await page.getByRole('textbox', { name: 'IstioGateways (main namespace)', exact: true }).fill(cell.eic.namespaces.gateways);

    // Load Balancer Provider is left untouched

    // Final step: Deploy
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();
    await page.getByRole('button', { name: 'Deploy', description: 'Default Action' }).click();
  },

  async downloadEicZip(page, { clusterName, deployment, dir }) {
    // Find the deployment row and click it to open Operations menu
    const table = page.getByRole('grid', { name: 'All Deployments', exact: true });
    const row = table.getByText(deployment, { exact: true });
    await row.click();

    // Click Operations menu
    await page.getByLabel('Operations', { exact: true }).click();

    // Click Download Kubernetes Resources
    await page.getByText('Download Kubernetes Resources', { exact: true }).click();

    // Click Download button and wait for download
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.getByRole('button', { name: 'Download', description: 'Default Action' }).click(),
    ]);

    const filename = download.suggestedFilename();
    const path = join(dir, basename(filename));
    await download.saveAs(path);
    return path;
  },

  async resumeEicDeployment(page, { clusterName, deployment }) {
    // Find the deployment row and click it to open Operations menu
    const table = page.getByRole('grid', { name: 'All Deployments', exact: true });
    const row = table.getByText(deployment, { exact: true });
    await row.click();

    // Click Operations menu
    await page.getByLabel('Operations', { exact: true }).click();

    // Click Resume Operation
    await page.getByText('Resume Operation', { exact: true }).click();

    // Click Resume button
    await page.getByRole('button', { name: 'Resume', exact: true }).click();
  },

  async eicDeploymentStatus(page, { clusterName, deployment }) {
    const table = page.getByRole('grid', { name: 'All Deployments', exact: true });
    const allRows = await table.locator('div').allInnerTexts();

    for (const rowText of allRows) {
      // Match deployment name exactly - use word boundary or space to prevent pr-1-eic-1 matching pr-1-eic-10
      const deploymentPattern = new RegExp(`\\b${deployment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`);
      if (deploymentPattern.test(rowText)) {
        // Parse the row text to extract status, operation, and version
        // Format: "Running Object Status Entry successfully validated pr-1-eic-1 8.48.16 ... Last Operation Status : Successful"
        // or: "Initial Object Status pr-1-eic-1 8.48.16 ..."
        const versionMatch = rowText.match(/(\d+\.\d+\.\d+)/);
        const statusMatch = rowText.match(/^(\w+)\s+Object Status/);
        const operationMatch = rowText.match(/Last Operation Status\s*:\s*(\w+)/i);

        if (versionMatch && statusMatch) {
          return {
            operation: operationMatch ? operationMatch[1] : statusMatch[1],
            status: statusMatch[1],
            version: versionMatch[1],
          };
        }
      }
    }

    return null;
  },

  async upgradeEic(page, { clusterName, deployment, version }) {
    // Find the deployment row and click it to open Operations menu
    const table = page.getByRole('grid', { name: 'All Deployments', exact: true });
    const row = table.getByText(deployment, { exact: true });
    await row.click();

    // Click Operations menu
    await page.getByLabel('Operations', { exact: true }).click();

    // Click Upgrade menu option (first occurrence)
    await page.getByText('Upgrade', { exact: true }).first().click();

    // Select the version from the list
    const versionList = page.locator('[id$="--versionsListUpgrade-list"]');
    const versionOption = versionList.getByText(version, { exact: true });
    if (await versionOption.count() === 0) {
      throw new SetupError(`EIC version ${version} is not offered by ELM.`);
    }
    await versionOption.click();

    // Click Next Step 4 times
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();
    await page.getByRole('button', { name: 'Next Step', exact: true }).click();

    // Click Upgrade button
    await page.getByRole('button', { name: 'Upgrade', exact: true }).click();
  },

  async deleteEicDeployment(page, { clusterName, deployment }) {
    // Find the deployment row and click it to open Operations menu
    const table = page.getByRole('grid', { name: 'All Deployments', exact: true });
    const row = table.getByText(deployment, { exact: true });
    await row.click();

    // Click Operations menu
    await page.getByLabel('Operations', { exact: true }).click();

    // Click Delete menu option (first occurrence)
    await page.getByText('Delete', { exact: true }).first().click();

    // Confirm deletion with the Delete button
    await page.getByRole('button', { name: 'Delete', exact: true }).click();
  },

  async removeEdgeNode(page, { clusterName }) {
    // Click the Remove button in the header
    await page.getByRole('button', { name: 'Remove', exact: true }).click();

    // Type the node name in the confirmation textbox
    await page.getByRole('textbox', { name: 'Edge Node Name', exact: true }).fill(clusterName);

    // Click Remove button
    await page.getByRole('button', { name: 'Remove', description: 'Default Action' }).click();
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
