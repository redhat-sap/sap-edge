// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { chromium } from 'playwright';
import { reviewRegistration } from './registration.mjs';

let browser;
before(async () => {
  browser = await chromium.launch({ headless: true, channel: process.env.SAP_BROWSER_TEST_CHANNEL || undefined });
});
after(async () => { await browser?.close(); });

// Exercise the real browser against an isolated wizard. No SAP or cluster access.
async function fixture(existing = '') {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  await page.setContent(`
    <label>Search by Edge Node name<input type="search"></label>
    <div role="grid" aria-label="All Edge Nodes">Name<span>${existing}</span></div>
    <button id="add">Add</button>
    <section id="details" hidden>
      <label>Edge Node Name<input id="node"></label>
      <label>Main Namespace<input id="namespace"></label>
      <label><input type="checkbox" id="restricted">Restricted Access to Kubernetes Cluster</label>
      <label><input type="checkbox" id="ha">High Availability Mode</label>
      <label><input type="checkbox" id="connector">External Cloud Connector</label>
      <button id="step2">Step 2</button>
    </section>
    <section id="registry" hidden>
      <label><input type="checkbox" id="replicate">Replicate Container Images</label>
      <button id="step3">Step 3</button>
    </section>
    <section id="proxy" hidden>
      <label><input type="checkbox" id="proxy-enabled">Enable HTTP Proxy</label>
      <button id="review">Review</button>
    </section>
    <section id="summary" hidden><h2>Configuration Review</h2><button id="submit">Add Edge Node</button></section>
    <output id="submitted">false</output>
    <script>
      for (const [button, section] of [['add','details'],['step2','registry'],['step3','proxy'],['review','summary']]) {
        document.getElementById(button).onclick = () => setTimeout(() => {
          document.getElementById(section).hidden = false;
        }, 75);
      }
      document.getElementById('submit').onclick = () => document.getElementById('submitted').textContent = 'true';
    </script>`);
  return page;
}

test('fills a restricted registration through review without submitting', async () => {
  const page = await fixture();
  try {
    await reviewRegistration(page, { clusterName: 'hcp-demo', highAvailability: true });
    assert.equal(await page.locator('#node').inputValue(), 'hcp-demo');
    assert.equal(await page.locator('#namespace').inputValue(), 'edgelm');
    assert.equal(await page.locator('#restricted').isChecked(), true);
    assert.equal(await page.locator('#ha').isChecked(), true);
    assert.equal(await page.locator('#summary').isVisible(), true);
    assert.equal(await page.locator('#submitted').innerText(), 'false');
  } finally { await page.close(); }
});

test('stops when the requested node exists', async () => {
  const page = await fixture('hcp-demo');
  try {
    await assert.rejects(reviewRegistration(page, { clusterName: 'hcp-demo' }), /already exists/);
    assert.equal(await page.locator('#details').isVisible(), false);
    assert.equal(await page.locator('#submitted').innerText(), 'false');
  } finally { await page.close(); }
});
