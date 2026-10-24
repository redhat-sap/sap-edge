// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { SetupError } from './inputs.mjs';

// Labels observed in the ELM registration wizard on 2026-10-22.
// This flow deliberately ends at Configuration Review; it does not submit.
export async function reviewRegistration(page, { clusterName, highAvailability = false, onStep = () => {} }) {
  await onStep('Check existing edge nodes');
  const table = page.getByRole('grid', { name: 'All Edge Nodes', exact: true });
  await table.waitFor({ state: 'visible' });
  // Clear a user's filter before checking for duplicates.
  const search = page.getByRole('searchbox', { name: 'Search by Edge Node name', exact: true });
  await search.fill('');
  await search.press('Enter');
  if (await table.getByText(clusterName, { exact: true }).count()) {
    throw new SetupError('An edge node with this name already exists. Inspect its state before continuing.');
  }

  await onStep('Fill registration details');
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await page.getByRole('textbox', { name: 'Edge Node Name', exact: true }).fill(clusterName);
  await page.getByRole('textbox', { name: 'Main Namespace', exact: true }).fill('edgelm');
  await page.getByRole('checkbox', { name: 'Restricted Access to Kubernetes Cluster', exact: true }).check();
  await page.getByRole('checkbox', { name: 'High Availability Mode', exact: true }).setChecked(highAvailability);
  await page.getByRole('checkbox', { name: 'External Cloud Connector', exact: true }).uncheck();
  await onStep('Configure image replication');
  await page.getByRole('button', { name: 'Step 2', exact: true }).click();
  await page.getByRole('checkbox', { name: 'Replicate Container Images', exact: true }).uncheck();
  await onStep('Configure HTTP proxy');
  await page.getByRole('button', { name: 'Step 3', exact: true }).click();
  await page.getByRole('checkbox', { name: 'Enable HTTP Proxy', exact: true }).uncheck();
  await onStep('Open Configuration Review');
  await page.getByRole('button', { name: 'Review', exact: true }).click();
  await page.getByRole('heading', { name: 'Configuration Review', exact: true }).waitFor({ state: 'visible' });
  await page.getByRole('button', { name: 'Add Edge Node', exact: true }).waitFor({ state: 'visible' });
}
