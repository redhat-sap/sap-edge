// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { SetupError } from './inputs.mjs';

// Playwright's check() fails at once when a click does not toggle the box, and in ELM a click
// can get lost while UI5 redraws the form (a field losing focus updates the model). The box is
// clicked again until it shows the state; a late toggle has 3 seconds before the next click.
export async function setBoxState(page, box, label, state, { attempts = 3, waitMs = 3000 } = {}) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    if (await box.isChecked() === state) return;
    await box.click();
    const deadline = Date.now() + waitMs;
    while (Date.now() < deadline) {
      if (await box.isChecked() === state) return;
      await page.waitForTimeout(100);
    }
  }
  throw new SetupError(`The ELM checkbox "${label}" did not change.`);
}

export function setCheckbox(page, name, state, options) {
  return setBoxState(page, page.getByRole('checkbox', { name, exact: true }), name, state, options);
}

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
  await setCheckbox(page, 'Restricted Access to Kubernetes Cluster', true);
  await setCheckbox(page, 'High Availability Mode', highAvailability);
  await setCheckbox(page, 'External Cloud Connector', false);

  const replicate = page.getByRole('checkbox', { name: 'Replicate Container Images', exact: true });
  await advance(page, 'Step 2', replicate);
  await setCheckbox(page, 'Replicate Container Images', Boolean(registry));
  if (registry) {
    await page.getByRole('textbox', { name: 'Local Container Registry URL', exact: true }).fill(registry.url);
    await page.getByRole('textbox', { name: 'Username', exact: true }).fill(registry.username);
    await page.getByRole('textbox', { name: 'Password', exact: true }).fill(registry.password);
    await setCheckbox(page, 'Non-Trusted Certificate', true);
    await page.getByRole('button', { name: 'Certificate with Public Key', exact: true }).setInputFiles(registry.caCertificateFile);
  }

  const proxy = page.getByRole('checkbox', { name: 'Enable HTTP Proxy', exact: true });
  await advance(page, 'Step 3', proxy);
  await setCheckbox(page, 'Enable HTTP Proxy', false);
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
