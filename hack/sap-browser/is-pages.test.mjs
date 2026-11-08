// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { chromium } from 'playwright';
import { ARTIFACTS, runtimeLocationId, runtimeName, isPages } from './is-pages.mjs';

let browser;
before(async () => {
  browser = await chromium.launch({ headless: true, channel: process.env.SAP_BROWSER_TEST_CHANNEL || undefined });
});
after(async () => { await browser?.close(); });

test('runtime_names', async () => {
  assert.equal(runtimeName('pr-1-eic-2'), 'Edge Integration Cell - pr-1-eic-2');
  assert.equal(runtimeLocationId('pr-1-eic-2'), 'pr1eic2');
  assert.equal(runtimeLocationId('hcp-dedicated-eli-pr167-eic-2'), 'hcpdedicatedelipr167eic2');
});

test('keystore_deployed_to_all_runtimes', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <style>
        div, button { min-height: 20px; padding: 5px; display: block; }
      </style>
      <!-- All elements visible for testing -->
      <div role="treeitem">Monitor</div>
      <div role="treeitem">Integrations and APIs</div>
      <div>Keystore5Entries</div>
      <div id="keystore--selRuntimeLocation-arrow" role="combobox">
        <div class="list" hidden><div>All</div></div>
      </div>
      <button id="edit-btn">Edit</button>
      <div role="combobox" aria-label="Runtimes">
        <div class="list" hidden>
          <div>Edge Integration Cell - pr-1-eic-1</div>
          <div>Edge Integration Cell - pr-1-eic-2</div>
        </div>
      </div>
      <button id="deploy-btn">Deploy</button>
      <output id="deployed-runtimes"></output>
      <script>
        document.getElementById('keystore--selRuntimeLocation-arrow').onclick = () => {
          const list = document.querySelector('#keystore--selRuntimeLocation-arrow .list');
          list.hidden = !list.hidden;
        };

        document.querySelectorAll('#keystore--selRuntimeLocation-arrow .list div').forEach(div => {
          div.onclick = () => {
            document.getElementById('edit-btn').disabled = false;
            document.querySelector('#keystore--selRuntimeLocation-arrow .list').hidden = true;
          };
        });

        const runtimesCombobox = document.querySelector('[aria-label="Runtimes"]');
        runtimesCombobox.onclick = () => {
          const list = runtimesCombobox.querySelector('.list');
          list.hidden = !list.hidden;
        };

        document.querySelectorAll('[aria-label="Runtimes"] .list div').forEach(div => {
          div.onclick = () => {
            const current = document.getElementById('deployed-runtimes').textContent;
            document.getElementById('deployed-runtimes').textContent = current ? current + ',' + div.textContent : div.textContent;
            document.querySelector('[aria-label="Runtimes"] .list').hidden = true;
          };
        });

        document.getElementById('deploy-btn').onclick = () => {
          document.getElementById('deployed-runtimes').textContent += '|deployed';
        };
      </script>
    `);

    await isPages.deployKeystore(page, { runtimes: ['pr-1-eic-1', 'pr-1-eic-2'] });

    const deployed = await page.locator('#deployed-runtimes').innerText();
    assert.match(deployed, /Edge Integration Cell - pr-1-eic-1/);
    assert.match(deployed, /Edge Integration Cell - pr-1-eic-2/);
    assert.match(deployed, /deployed/);
  } finally { await page.close(); }
});

test('notifications_dialog_declined', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <style>
        div, button { min-height: 20px; padding: 5px; display: block; }
      </style>
      <div role="treeitem">Monitor</div>
      <div role="treeitem">Integrations and APIs</div>
      <div>Keystore5Entries</div>
      <div id="keystore--selRuntimeLocation-arrow" role="combobox">
        <div class="list" hidden><div>All</div></div>
      </div>
      <button id="edit-btn">Edit</button>
      <div role="combobox" aria-label="Runtimes">
        <div class="list" hidden><div>Edge Integration Cell - pr-1-eic-1</div></div>
      </div>
      <button id="deploy-btn">Deploy</button>
      <dialog id="notifications">
        <button id="decline-btn">Decline</button>
      </dialog>
      <output id="declined">false</output>
      <script>
        document.getElementById('notifications').style.display = 'none';

        document.getElementById('keystore--selRuntimeLocation-arrow').onclick = () => {
          const list = document.querySelector('#keystore--selRuntimeLocation-arrow .list');
          list.hidden = !list.hidden;
        };

        document.querySelectorAll('#keystore--selRuntimeLocation-arrow .list div').forEach(div => {
          div.onclick = () => {
            document.getElementById('edit-btn').disabled = false;
            document.querySelector('#keystore--selRuntimeLocation-arrow .list').hidden = true;
          };
        });

        const runtimesCombobox = document.querySelector('[aria-label="Runtimes"]');
        runtimesCombobox.onclick = () => {
          const list = runtimesCombobox.querySelector('.list');
          list.hidden = !list.hidden;
        };

        document.querySelectorAll('[aria-label="Runtimes"] .list div').forEach(div => {
          div.onclick = () => {
            document.querySelector('[aria-label="Runtimes"] .list').hidden = true;
          };
        });

        document.getElementById('deploy-btn').onclick = () => {
          setTimeout(() => {
            document.getElementById('notifications').style.display = 'block';
          }, 50);
        };

        document.getElementById('decline-btn').onclick = () => {
          document.getElementById('declined').textContent = 'true';
          document.getElementById('notifications').style.display = 'none';
        };
      </script>
    `);

    await isPages.deployKeystore(page, { runtimes: ['pr-1-eic-1'] });
    assert.equal(await page.locator('#declined').innerText(), 'true');
  } finally { await page.close(); }
});

test('artifact_deployed_to_runtime_profile', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.goto('about:blank#/shell/design/contentpackage/APIMUsecases?section=ARTIFACTS');
    await page.setContent(`
      <style>
        div, button, section { min-height: 20px; padding: 5px; display: block; }
      </style>
      <section>
        <h2 aria-label="Artifacts (2)">Artifacts (2)</h2>
        <div id="artifact-row">Item Selection ipfilterAPI Flow ...</div>
      </section>
      <button aria-label="Actions">Actions</button>
      <button id="deploy-option">Deploy</button>
      <div id="deploy--runtimeProfile-arrow" role="combobox" style="display: none">
        <div class="list" hidden>
          <div>Edge Integration Cell - pr-1-eic-1</div>
          <div>Edge Integration Cell - pr-1-eic-2</div>
        </div>
      </div>
      <button id="deploy-btn" style="display: none">Deploy</button>
      <output id="deployed-to"></output>
      <script>
        document.getElementById('deploy-option').onclick = () => {
          document.getElementById('deploy-option').style.display = 'none';
          document.getElementById('deploy--runtimeProfile-arrow').style.display = 'block';
          document.getElementById('deploy-btn').style.display = 'block';
        };

        document.getElementById('deploy--runtimeProfile-arrow').onclick = () => {
          const list = document.querySelector('#deploy--runtimeProfile-arrow .list');
          list.hidden = !list.hidden;
        };

        document.querySelectorAll('#deploy--runtimeProfile-arrow .list div').forEach(div => {
          div.onclick = () => {
            document.getElementById('deployed-to').textContent = div.textContent;
            document.querySelector('#deploy--runtimeProfile-arrow .list').hidden = true;
          };
        });

        document.getElementById('deploy-btn').onclick = () => {
          document.getElementById('deployed-to').textContent += '|deployed';
        };
      </script>
    `);

    await isPages.deployArtifact(page, { pkg: 'APIMUsecases', artifact: 'ipfilterAPI', deployment: 'pr-1-eic-2' });

    const deployed = await page.locator('#deployed-to').innerText();
    assert.match(deployed, /Edge Integration Cell - pr-1-eic-2/);
    assert.match(deployed, /deployed/);
  } finally { await page.close(); }
});

test('artifact_states_parsed', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    const encodedPath = encodeURIComponent('{"edge":{"runtimeLocationId":"pr1eic2"}}');
    await page.goto(`about:blank#/shell/monitoring/Overview/${encodedPath}`);
    await page.setContent(`
      <div id="tile">All4Started</div>
      <div role="grid">
        <div>ipfilterAPI Started API Last Modified: 2026-11-03</div>
        <div>testAPI Started API Last Modified: 2026-11-03</div>
        <div>Arp_https Started Integration Flow Last Modified: 2026-11-03</div>
        <div>SLV_FLOW_ELSTER Started Integration Flow Last Modified: 2026-11-03</div>
      </div>
      <button>Reload content</button>
    `);

    const states = await isPages.artifactStates(page, { deployment: 'pr-1-eic-2' });

    assert.deepEqual(states, {
      ipfilterAPI: 'Started',
      testAPI: 'Started',
      Arp_https: 'Started',
      SLV_FLOW_ELSTER: 'Started',
    });
  } finally { await page.close(); }
});

test('runtime_ready_after_refresh', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <style>
        div, button { min-height: 20px; padding: 5px; display: block; }
      </style>
      <div role="treeitem">Operate</div>
      <div role="combobox" aria-label="Edge Integration Cell:">
        <div class="list" hidden>
          <div>pr-1-eic-1</div>
          <div>pr-1-eic-2</div>
        </div>
      </div>
      <button id="refresh-btn">Refresh</button>
      <button id="refresh-busy-btn" style="display: none">Refresh Busy</button>
      <output id="ready">false</output>
      <script>
        document.getElementById('refresh-btn').style.display = 'none';

        const combobox = document.querySelector('[aria-label="Edge Integration Cell:"]');
        combobox.onclick = () => {
          const list = combobox.querySelector('.list');
          list.hidden = !list.hidden;
        };

        combobox.querySelectorAll('.list div').forEach(div => {
          div.onclick = () => {
            document.getElementById('refresh-btn').style.display = 'block';
            combobox.querySelector('.list').hidden = true;
          };
        });

        document.getElementById('refresh-btn').onclick = () => {
          document.getElementById('refresh-btn').style.display = 'none';
          document.getElementById('refresh-busy-btn').style.display = 'block';
          setTimeout(() => {
            document.getElementById('refresh-busy-btn').style.display = 'none';
            document.getElementById('refresh-btn').style.display = 'block';
            document.getElementById('ready').textContent = 'true';
          }, 100);
        };
      </script>
    `);

    const ready = await isPages.runtimeReady(page, { deployment: 'pr-1-eic-2' });
    assert.equal(ready, true);
    assert.equal(await page.locator('#ready').innerText(), 'true');
  } finally { await page.close(); }
});
