// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { SetupError } from './inputs.mjs';

// A wizard button shows only when its step is valid, and a click can get lost while UI5 redraws
// the form (checking Restricted Access adds two info boxes), so the button is clicked again
// until the next step is visible.
async function advance(page, buttonName, next, { attempts = 3, waitMs = 5000 } = {}) {
  const button = page.getByRole('button', { name: buttonName, exact: true });
  for (let attempt = 1; ; attempt++) {
    // The first click waits for the button; later ones only if it is still there.
    if (attempt === 1 || await button.isVisible()) await button.click();
    try {
      await next.waitFor({ state: 'visible', timeout: waitMs });
      return;
    } catch {
      if (attempt >= attempts) throw new SetupError(`The ELM wizard did not continue after "${buttonName}".`);
    }
  }
}

// Fills the registration wizard up to the visible "Add Edge Node" button. The wizard only moves
// forward: Configuration Review has Edit links, not the step buttons.
export async function fillRegistration(page, { clusterName, highAvailability = false, registry = null }) {
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await page.getByRole('textbox', { name: 'Edge Node Name', exact: true }).fill(clusterName);
  await page.getByRole('textbox', { name: 'Main Namespace', exact: true }).fill('edgelm');
  await page.getByRole('checkbox', { name: 'Restricted Access to Kubernetes Cluster', exact: true }).check();
  await page.getByRole('checkbox', { name: 'High Availability Mode', exact: true }).setChecked(highAvailability);
  await page.getByRole('checkbox', { name: 'External Cloud Connector', exact: true }).uncheck();

  const replicate = page.getByRole('checkbox', { name: 'Replicate Container Images', exact: true });
  await advance(page, 'Step 2', replicate);
  if (registry) {
    await replicate.check();
    await page.getByRole('textbox', { name: 'Local Container Registry URL', exact: true }).fill(registry.url);
    await page.getByRole('textbox', { name: 'Username', exact: true }).fill(registry.username);
    await page.getByRole('textbox', { name: 'Password', exact: true }).fill(registry.password);
    await page.getByRole('checkbox', { name: 'Non-Trusted Certificate', exact: true }).check();
    await page.getByRole('button', { name: 'Certificate with Public Key', exact: true }).setInputFiles(registry.caCertificateFile);
  } else {
    await replicate.uncheck();
  }

  const proxy = page.getByRole('checkbox', { name: 'Enable HTTP Proxy', exact: true });
  await advance(page, 'Step 3', proxy);
  await proxy.uncheck();
  await advance(page, 'Review', page.getByRole('heading', { name: 'Configuration Review', exact: true }));
  await page.getByRole('button', { name: 'Add Edge Node', exact: true }).waitFor({ state: 'visible' });
}

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
  await fillRegistration(page, { clusterName, highAvailability });
}
