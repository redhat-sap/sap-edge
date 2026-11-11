// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

export const ARTIFACTS = [
  { pkg: 'APIMUsecases', artifact: 'ipfilterAPI' },
  { pkg: 'APIMUsecases', artifact: 'testAPI' },
  { pkg: 'Arpith_Test', artifact: 'Arp_https' },
  { pkg: 'SLV_TEST_FLOW_ELSTER', artifact: 'SLV_FLOW_ELSTER' },
];

export function runtimeName(deployment) {
  return `Edge Integration Cell - ${deployment}`;
}

export function runtimeLocationId(deployment) {
  return deployment.replace(/-/g, '');
}

export const isPages = {
  async deployKeystore(page, { runtimes }) {
    // Navigate to Monitor -> Integrations and APIs
    const monitorItem = page.getByRole('treeitem', { name: 'Monitor', exact: true });
    await monitorItem.click();

    const integrationsItem = page.getByRole('treeitem', { name: 'Integrations and APIs', exact: true });
    await integrationsItem.click();

    // Click the Keystore tile
    await page.locator('div').filter({ hasText: /^Keystore\d+Entries$/ }).click();

    // Select "All" from runtime location
    const runtimeLocationSelect = page.locator('[id$="--selRuntimeLocation-arrow"]');
    await runtimeLocationSelect.click();
    await runtimeLocationSelect.locator('.list').getByText('All', { exact: true }).click();

    // Click Edit button
    await page.getByRole('button', { name: 'Edit', exact: true }).click();

    // Select all runtimes from the Runtimes combobox
    const runtimesCombobox = page.getByRole('combobox', { name: 'Runtimes', exact: true });
    for (const runtime of runtimes) {
      await runtimesCombobox.click();
      const runtimesList = runtimesCombobox.locator('.list');
      await runtimesList.getByText(runtimeName(runtime), { exact: true }).click();
    }

    // Click Deploy
    await page.getByRole('button', { name: 'Deploy', exact: true }).click();

    // Handle notifications dialog if it appears - wait briefly for it
    await page.waitForTimeout(100);
    const declineButton = page.getByRole('button', { name: 'Decline', exact: true });
    if (await declineButton.count() > 0) {
      await declineButton.click();
    }
  },

  async runtimeReady(page, { deployment }) {
    // Navigate to Operate
    const operateItem = page.getByRole('treeitem', { name: 'Operate', exact: true });
    await operateItem.click();

    // Select the deployment from the Edge Integration Cell combobox
    const eicCombobox = page.getByRole('combobox', { name: 'Edge Integration Cell:', exact: true });
    await eicCombobox.click();
    await eicCombobox.locator('.list').getByText(deployment, { exact: true }).click();

    // Click Refresh and wait for it to complete
    const refreshButton = page.getByRole('button', { name: 'Refresh', exact: true });
    await refreshButton.click();

    // Wait for Refresh Busy to disappear and Refresh to reappear
    await page.getByRole('button', { name: 'Refresh Busy', exact: true }).waitFor({ state: 'hidden', timeout: 30000 });

    return true;
  },

  async deployArtifact(page, { pkg, artifact, deployment }) {
    // Navigate to the package page
    const packagePath = `/shell/design/contentpackage/${pkg}?section=ARTIFACTS`;
    const packageUrl = new URL(packagePath, page.url());
    await page.goto(packageUrl.toString());

    // Find the artifact row in the Artifacts region
    const artifactsRegion = page.locator('section').filter({ has: page.locator('[aria-label*="Artifacts"]') });
    const artifactRow = artifactsRegion.locator('div').filter({ hasText: new RegExp(`Item Selection ${artifact}\\b`) });
    await artifactRow.click();

    // Click Actions
    await page.getByLabel('Actions', { exact: true }).click();

    // Click Deploy in the actions menu
    await page.getByRole('button', { name: 'Deploy', exact: true }).click();

    // Select runtime profile
    const runtimeProfileSelect = page.locator('[id$="--runtimeProfile-arrow"]');
    await runtimeProfileSelect.click();
    await runtimeProfileSelect.locator('.list').getByText(runtimeName(deployment), { exact: true }).click();

    // Click Deploy
    await page.getByRole('button', { name: 'Deploy', exact: true }).click();
  },

  async artifactStates(page, { deployment }) {
    // Navigate to the monitoring overview page
    const runtimeLocId = runtimeLocationId(deployment);
    const pathSegment = encodeURIComponent(`{"edge":{"runtimeLocationId":"${runtimeLocId}"}}`);
    const monitoringPath = `/shell/monitoring/Overview/${pathSegment}`;
    const monitoringUrl = new URL(monitoringPath, page.url());
    await page.goto(monitoringUrl.toString());

    // Parse the artifact states from the grid rows
    const grid = page.getByRole('grid');
    const rows = await grid.locator('div').allInnerTexts();

    const states = {};
    for (const row of rows) {
      // Match pattern: "<artifact> <state> ..."
      const match = row.match(/^(\S+)\s+(\w+)\s+/);
      if (match) {
        const [, artifactName, state] = match;
        // Only include artifacts from our ARTIFACTS list
        if (ARTIFACTS.some(a => a.artifact === artifactName)) {
          states[artifactName] = state;
        }
      }
    }

    return states;
  },
};
