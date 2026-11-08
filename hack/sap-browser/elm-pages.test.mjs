// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { chromium } from 'playwright';
import { elmPages } from './elm-pages.mjs';

let browser;
before(async () => {
  browser = await chromium.launch({ headless: true, channel: process.env.SAP_BROWSER_TEST_CHANNEL || undefined });
});
after(async () => { await browser?.close(); });

async function nodeListFixture(page, nodes = []) {
  await page.setContent(`
    <label>Search by Edge Node name<input type="search"></label>
    <div role="grid" aria-label="All Edge Nodes">
      ${nodes.map((n) => `<div>${n}</div>`).join('')}
    </div>
  `);
}

async function nodePageFixture(page, { status = 'Not Initialized', hasDeploymentsTab = false, url = '#/clusters/4711' }) {
  await page.goto(`about:blank${url}`);
  await page.setContent(`
    <div>Status: ${status}</div>
    ${hasDeploymentsTab ? '<div role="tab">Deployments</div>' : '<div role="tab">Initialize Edge Node</div>'}
  `);
}

async function errorPageFixture(page) {
  await page.goto('about:blank#/errorPage');
  await page.setContent('<button>Sign in again</button>');
}

test('state_absent_when_not_listed', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await nodeListFixture(page, ['other-node']);
    const state = await elmPages.edgeNodeState(page, 'hcp-x');
    assert.equal(state, 'absent');
  } finally { await page.close(); }
});

test('state_added_when_not_initialized', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    // Start on list page with the node listed, clicking it opens node page with Not Initialized
    await page.setContent(`
      <label>Search by Edge Node name<input type="search"></label>
      <div role="grid" aria-label="All Edge Nodes">
        <div id="node-row">hcp-x</div>
      </div>
      <script>
        document.getElementById('node-row').onclick = () => {
          // Simulate navigation to node page
          document.body.innerHTML = \`
            <div>Status: Not Initialized</div>
            <div role="tab">Initialize Edge Node</div>
          \`;
        };
      </script>
    `);
    const state = await elmPages.edgeNodeState(page, 'hcp-x');
    assert.equal(state, 'added');
  } finally { await page.close(); }
});

test('state_initialized_on_deployments_tab', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    // Start on list page with the node listed, clicking it opens node page with Deployments tab
    await page.setContent(`
      <label>Search by Edge Node name<input type="search"></label>
      <div role="grid" aria-label="All Edge Nodes">
        <div id="node-row">hcp-x</div>
      </div>
      <script>
        document.getElementById('node-row').onclick = () => {
          // Simulate navigation to initialized node page
          document.body.innerHTML = \`
            <div role="tab">Deployments</div>
            <div role="tab">Configuration</div>
          \`;
        };
      </script>
    `);
    const state = await elmPages.edgeNodeState(page, 'hcp-x');
    assert.equal(state, 'initialized');
  } finally { await page.close(); }
});

test('state_returns_unknown_status_text', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    // Already on node page (no list table)
    await page.setContent(`
      <div>Status: Initializing</div>
      <div role="tab">Initialize Edge Node</div>
    `);
    const state = await elmPages.edgeNodeState(page, 'hcp-x');
    assert.equal(state, 'Initializing');
  } finally { await page.close(); }
});

test('elm_id_from_node_url', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.goto('about:blank#/clusters/4711');
    await page.setContent('<div>node page</div>');
    const id = await elmPages.edgeNodeElmId(page);
    assert.equal(id, '4711');
  } finally { await page.close(); }
});

test('add_submits_registration', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <button id="add">Add</button>
      <section id="details" hidden>
        <div aria-label="Step1 Edge Node Details">
          <label>Edge Node Name<input id="node"></label>
          <label>Main Namespace<input id="namespace"></label>
          <label><input type="checkbox" id="restricted">Restricted Access to Kubernetes Cluster</label>
          <label><input type="checkbox" id="ha">High Availability Mode</label>
          <label><input type="checkbox" id="connector">External Cloud Connector</label>
        </div>
        <button id="step2">Step 2</button>
      </section>
      <section id="registry" hidden>
        <label><input type="checkbox" id="replicate">Replicate Container Images</label>
        <button id="step3">Step 3</button>
      </section>
      <section id="proxy" hidden>
        <label><input type="checkbox" id="proxy-cb">Enable HTTP Proxy</label>
        <button id="review">Review</button>
      </section>
      <section id="summary" hidden>
        <h2>Configuration Review</h2>
        <button id="submit">Add Edge Node</button>
      </section>
      <output id="submitted">false</output>
      <script>
        document.getElementById('add').onclick = () => setTimeout(() => document.getElementById('details').hidden = false, 50);
        document.getElementById('step2').onclick = () => setTimeout(() => document.getElementById('registry').hidden = false, 50);
        document.getElementById('step3').onclick = () => setTimeout(() => document.getElementById('proxy').hidden = false, 50);
        document.getElementById('review').onclick = () => setTimeout(() => document.getElementById('summary').hidden = false, 50);
        document.getElementById('submit').onclick = () => document.getElementById('submitted').textContent = 'true';
      </script>
    `);
    await elmPages.addEdgeNode(page, { clusterName: 'hcp-x', highAvailability: false });
    assert.equal(await page.locator('#node').inputValue(), 'hcp-x');
    assert.equal(await page.locator('#namespace').inputValue(), 'edgelm');
    assert.equal(await page.locator('#restricted').isChecked(), true);
    assert.equal(await page.locator('#ha').isChecked(), false);
    assert.equal(await page.locator('#replicate').isChecked(), false);
    assert.equal(await page.locator('#submitted').innerText(), 'true');
  } finally { await page.close(); }
});

test('add_with_registry_fills_replication', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const testCert = join(tmpdir(), `test-cert-${Date.now()}.pem`);
  await writeFile(testCert, 'fake-ca-cert\n');
  try {
    await page.setContent(`
      <button id="add">Add</button>
      <section id="details" hidden>
        <div aria-label="Step1 Edge Node Details">
          <label>Edge Node Name<input id="node"></label>
          <label>Main Namespace<input id="namespace"></label>
          <label><input type="checkbox" id="restricted">Restricted Access to Kubernetes Cluster</label>
          <label><input type="checkbox" id="ha">High Availability Mode</label>
          <label><input type="checkbox" id="connector">External Cloud Connector</label>
        </div>
        <button id="step2">Step 2</button>
      </section>
      <section id="registry" hidden>
        <label><input type="checkbox" id="replicate">Replicate Container Images</label>
        <label>Local Container Registry URL<input id="url"></label>
        <label>Username<input id="user"></label>
        <label>Password<input id="pass" type="password"></label>
        <label><input type="checkbox" id="untrusted">Non-Trusted Certificate</label>
        <input type="file" id="cert-upload" role="button" aria-label="Certificate with Public Key">
        <button id="step3">Step 3</button>
      </section>
      <section id="proxy" hidden>
        <label><input type="checkbox" id="proxy-cb">Enable HTTP Proxy</label>
        <button id="review">Review</button>
      </section>
      <section id="summary" hidden>
        <h2>Configuration Review</h2>
        <button id="submit">Add Edge Node</button>
      </section>
      <output id="submitted">false</output>
      <output id="cert-name"></output>
      <script>
        document.getElementById('add').onclick = () => setTimeout(() => document.getElementById('details').hidden = false, 50);
        document.getElementById('step2').onclick = () => setTimeout(() => document.getElementById('registry').hidden = false, 50);
        document.getElementById('step3').onclick = () => setTimeout(() => document.getElementById('proxy').hidden = false, 50);
        document.getElementById('review').onclick = () => setTimeout(() => document.getElementById('summary').hidden = false, 50);
        document.getElementById('submit').onclick = () => document.getElementById('submitted').textContent = 'true';
        document.getElementById('cert-upload').addEventListener('input', (e) => {
          if (e.target.files?.[0]) document.getElementById('cert-name').textContent = e.target.files[0].name;
        });
      </script>
    `);
    await elmPages.addEdgeNode(page, {
      clusterName: 'hcp-x',
      highAvailability: true,
      registry: {
        url: 'quay.example.com/repo',
        username: 'test-user',
        password: 'test-pass',
        caCertificateFile: testCert,
      },
    });
    assert.equal(await page.locator('#replicate').isChecked(), true);
    assert.equal(await page.locator('#url').inputValue(), 'quay.example.com/repo');
    assert.equal(await page.locator('#user').inputValue(), 'test-user');
    assert.equal(await page.locator('#pass').inputValue(), 'test-pass');
    assert.equal(await page.locator('#untrusted').isChecked(), true);
    assert.match(await page.locator('#cert-name').innerText(), /test-cert.*\.pem/);
    assert.equal(await page.locator('#submitted').innerText(), 'true');
  } finally { await page.close(); }
});

test('elm_zip_downloaded_and_confirmed', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const dir = await mkdtemp(join(tmpdir(), 'elm-zip-test-'));
  const expectedContent = 'fake-elm-zip-content-12345';
  try {
    await page.setContent(`
      <label><input type="checkbox" id="confirm">I confirm that I have downloaded and applied resources.</label>
      <button id="download-btn">Download Kubernetes Resources</button>
      <dialog id="dialog" hidden>
        <button id="download-action" title="Default Action">Download</button>
      </dialog>
      <button id="next">Next Step</button>
      <output id="next-clicked">false</output>
      <script>
        document.getElementById('download-btn').onclick = () => {
          const dialog = document.getElementById('dialog');
          dialog.hidden = false;
          dialog.style.display = 'block';
        };
        document.getElementById('download-action').onclick = () => {
          // Trigger a real download using data URI
          const content = 'fake-elm-zip-content-12345';
          const base64 = btoa(content);
          const a = document.createElement('a');
          a.href = 'data:application/zip;base64,' + base64;
          a.download = 'restricted-resources-Edge_Lifecycle_Management-1.65.0.zip';
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
        };
        document.getElementById('next').onclick = () => document.getElementById('next-clicked').textContent = 'true';
      </script>
    `);

    const zipPath = await elmPages.downloadElmZip(page, { clusterName: 'hcp-x', dir });

    assert.match(zipPath, /restricted-resources-Edge_Lifecycle_Management-.*\.zip$/);
    const fileContent = await readFile(zipPath, 'utf8');
    assert.equal(fileContent, expectedContent);
    assert.equal(await page.locator('#confirm').isChecked(), true);
    assert.equal(await page.locator('#next-clicked').innerText(), 'true');
  } finally {
    await page.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('cloud_connector_returns_context_cfg', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const dir = await mkdtemp(join(tmpdir(), 'cloud-connector-test-'));
  const kubeconfigFile = join(dir, `test-kubeconfig-${Date.now()}.yaml`);
  const expectedContent = 'fake-context-cfg-content-67890';
  await writeFile(kubeconfigFile, 'fake-kubeconfig\n');
  try {
    await page.setContent(`
      <div aria-label="Browse or drop a file">
        <div title="Browse or drop a file">
          <input type="file" id="kubeconfig-upload" role="button" aria-label="Kubeconfig File">
        </div>
      </div>
      <label>Context Password<input id="password" type="password"></label>
      <button id="download-btn">Download Bootstrapping File</button>
      <output id="kube-name"></output>
      <script>
        document.getElementById('kubeconfig-upload').addEventListener('input', (e) => {
          if (e.target.files?.[0]) document.getElementById('kube-name').textContent = e.target.files[0].name;
        });
        document.getElementById('download-btn').onclick = () => {
          // Trigger a real download using data URI
          const content = 'fake-context-cfg-content-67890';
          const base64 = btoa(content);
          const a = document.createElement('a');
          a.href = 'data:application/octet-stream;base64,' + base64;
          a.download = 'context.cfg';
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
        };
      </script>
    `);

    const contextPath = await elmPages.setUpCloudConnector(page, {
      clusterName: 'hcp-x',
      kubeconfigFile,
      password: 'test-password',
      dir,
    });

    assert.match(contextPath, /context\.cfg$/);
    const fileContent = await readFile(contextPath, 'utf8');
    assert.equal(fileContent, expectedContent);
    assert.match(await page.locator('#kube-name').innerText(), /test-kubeconfig.*\.yaml/);
    assert.equal(await page.locator('#password').inputValue(), 'test-password');
  } finally {
    await page.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('session_expired_detected', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await errorPageFixture(page);
    assert.equal(await elmPages.isSessionExpired(page), true);

    await nodePageFixture(page, {});
    assert.equal(await elmPages.isSessionExpired(page), false);
  } finally { await page.close(); }
});
