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

test('deploy_fills_all_steps', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const dir = await mkdtemp(join(tmpdir(), 'deploy-test-'));
  const postgresCA = join(dir, 'postgres-ca.crt');
  const redisCA = join(dir, 'redis-ca.pem');
  await writeFile(postgresCA, 'fake-postgres-ca\n');
  await writeFile(redisCA, 'fake-redis-ca\n');
  try {
    await page.setContent(`
      <button id="deploy-solution">Deploy Solution</button>
      <section id="solution-step" style="display: none">
        <div id="deploy--solutionsList-arrow" role="combobox" aria-label="Solution">
          <span class="selected">Edge Integration Cell (dev)</span>
          <div class="list" hidden><div>Edge Integration Cell (dev)</div></div>
        </div>
        <label>Deployment Name<input id="deployment-name"></label>
        <div id="deploy--versionCombo-arrow" role="combobox" aria-label="Version">
          <span class="selected">8.48.16</span>
          <div class="list" hidden><div>8.48.16</div></div>
        </div>
        <button id="step1">Next Step</button>
      </section>
      <section id="namespace-step" style="display: none">
        <div id="deploy--namespacesForm--Form--Grid">
          <label>Edge Integration Cell (main namespace)<input id="main-ns"></label>
          <label>Edge Security Artifact Secrets<input id="secrets-ns"></label>
          <label>Edge Local Authorization<input id="ela-ns"></label>
          <label>Default Virtual Host<input id="vhost"></label>
          <label>Default Virtual Host Key Alias<input id="key-alias"></label>
          <label><input type="checkbox" id="shared-fs">Enable shared file system</label>
          <label>Shared File System Storage<input id="storage-class"></label>
        </div>
        <button id="step2a">Next Step</button>
      </section>
      <section id="step2" style="display: none">
        <button id="step2-next">Next Step</button>
      </section>
      <section id="services-step" style="display: none">
        <label>Deployment Name<input id="services-deployment"></label>
        <label>Edge Integration Cell<input id="services-ns"></label>
        <div role="combobox" aria-label="Database Type"><span>PostgreSQL</span></div>
        <div role="combobox" aria-label="Datastore Type"><span>Redis</span></div>
        <label>PostgreSQL Hostname<input id="pg-host"></label>
        <label>PostgreSQL Port<input id="pg-port"></label>
        <label>PostgreSQL DB Name<input id="pg-db"></label>
        <label>PostgreSQL Username<input id="pg-user"></label>
        <label>PostgreSQL Password<input id="pg-pass" type="password"></label>
        <input type="file" id="pg-ca" role="button" title="Activate to Select a File" aria-label="Browse or drop a file">
        <label>Redis Addresses<input id="redis-addr"></label>
        <div role="combobox" aria-label="Redis Mode"><span>standalone</span></div>
        <label>Redis Password<input id="redis-pass" type="password"></label>
        <input type="file" id="redis-ca" role="button" title="Activate to Select a File" aria-label="Browse or drop a file">
        <label>Redis Server Name<input id="redis-server"></label>
        <button id="step3">Next Step</button>
      </section>
      <section id="gateways-step" style="display: none">
        <label>Deployment Name<input id="gateways-deployment"></label>
        <label>IstioGateways (main namespace)<input id="gateways-ns"></label>
        <div role="combobox" aria-label="Load Balancer Provider"><span>Other</span></div>
        <button id="step4">Next Step</button>
      </section>
      <section id="review-step" style="display: none">
        <button id="deploy" title="Default Action">Deploy</button>
      </section>
      <output id="deployed">false</output>
      <script>
        const sections = ['solution-step', 'namespace-step', 'step2', 'services-step', 'gateways-step', 'review-step'];
        function showOnly(id) {
          sections.forEach(s => document.getElementById(s).style.display = 'none');
          document.getElementById(id).style.display = 'block';
        }
        document.getElementById('deploy-solution').onclick = () => showOnly('solution-step');
        document.getElementById('deploy--solutionsList-arrow').onclick = () => {
          const list = document.getElementById('deploy--solutionsList-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
        document.getElementById('deploy--versionCombo-arrow').onclick = () => {
          const list = document.getElementById('deploy--versionCombo-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
        document.getElementById('step1').onclick = () => showOnly('namespace-step');
        document.getElementById('step2a').onclick = () => showOnly('step2');
        document.getElementById('step2-next').onclick = () => showOnly('services-step');
        document.getElementById('step3').onclick = () => showOnly('gateways-step');
        document.getElementById('step4').onclick = () => showOnly('review-step');
        document.getElementById('deploy').onclick = () => document.getElementById('deployed').textContent = 'true';
      </script>
    `);

    const cell = {
      deployment: 'pr-1-eic-1',
      eic: {
        solution: 'Edge Integration Cell (dev)',
        version: '8.48.16',
        namespaces: {
          main: 'edge-icell-1',
          secrets: 'edge-icell-secrets-1',
          ela: 'edge-icell-ela-1',
          services: 'edge-icell-services-1',
          gateways: 'istio-gateways-1',
        },
        virtualHost: 'eic-1.apps.x',
        keyAlias: 'slv-ic',
        sharedFsStorageClass: 'nfs-rwx',
        servicesDeployment: 'pr-1-eic-1-services',
        gatewaysDeployment: 'pr-1-eic-1-gateways',
      },
      services: {
        postgres: {
          host: 'edgedb-primary.sap-eic-external-postgres.svc',
          port: '5432',
          database: 'edgedb',
          username: 'edgedb',
          password: 'test-pg-pass',
        },
        datastore: {
          type: 'redis',
          address: 'redb-headless.sap-eic-external-redis-eic-1.svc:6379',
          mode: 'standalone',
          password: 'test-redis-pass',
          serverName: 'rec.sap-eic-external-redis-eic-1.svc.cluster.local',
          username: '',
        },
      },
      files: {
        postgresCA,
        redisCA,
      },
    };

    await elmPages.deployEic(page, { clusterName: 'hcp-x', cell });

    assert.equal(await page.locator('#deployment-name').inputValue(), 'pr-1-eic-1');
    assert.equal(await page.locator('#main-ns').inputValue(), 'edge-icell-1');
    assert.equal(await page.locator('#secrets-ns').inputValue(), 'edge-icell-secrets-1');
    assert.equal(await page.locator('#ela-ns').inputValue(), 'edge-icell-ela-1');
    assert.equal(await page.locator('#vhost').inputValue(), 'eic-1.apps.x');
    assert.equal(await page.locator('#key-alias').inputValue(), 'slv-ic');
    assert.equal(await page.locator('#shared-fs').isChecked(), true);
    assert.equal(await page.locator('#storage-class').inputValue(), 'nfs-rwx');
    assert.equal(await page.locator('#services-deployment').inputValue(), 'pr-1-eic-1-services');
    assert.equal(await page.locator('#services-ns').inputValue(), 'edge-icell-services-1');
    assert.equal(await page.locator('#pg-host').inputValue(), 'edgedb-primary.sap-eic-external-postgres.svc');
    assert.equal(await page.locator('#pg-port').inputValue(), '5432');
    assert.equal(await page.locator('#pg-db').inputValue(), 'edgedb');
    assert.equal(await page.locator('#pg-user').inputValue(), 'edgedb');
    assert.equal(await page.locator('#pg-pass').inputValue(), 'test-pg-pass');
    assert.equal(await page.locator('#redis-addr').inputValue(), 'redb-headless.sap-eic-external-redis-eic-1.svc:6379');
    assert.equal(await page.locator('#redis-pass').inputValue(), 'test-redis-pass');
    assert.equal(await page.locator('#redis-server').inputValue(), 'rec.sap-eic-external-redis-eic-1.svc.cluster.local');
    assert.equal(await page.locator('#gateways-deployment').inputValue(), 'pr-1-eic-1-gateways');
    assert.equal(await page.locator('#gateways-ns').inputValue(), 'istio-gateways-1');
    assert.equal(await page.locator('#deployed').innerText(), 'true');
  } finally {
    await page.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('deploy_version_not_offered_hands_over', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <button id="deploy-solution">Deploy Solution</button>
      <section id="solution-step" style="display: none">
        <div id="deploy--solutionsList-arrow" role="combobox" aria-label="Solution">
          <span class="selected">Edge Integration Cell (dev)</span>
          <div class="list" hidden><div>Edge Integration Cell (dev)</div></div>
        </div>
        <label>Deployment Name<input id="deployment-name"></label>
        <div id="deploy--versionCombo-arrow" role="combobox" aria-label="Version">
          <span class="selected">8.48.16</span>
          <div class="list" hidden><div>8.48.16</div></div>
        </div>
        <button id="step1">Next Step</button>
      </section>
      <output id="deployed">false</output>
      <script>
        document.getElementById('deploy-solution').onclick = () => {
          document.getElementById('solution-step').style.display = 'block';
        };
        document.getElementById('deploy--solutionsList-arrow').onclick = () => {
          const list = document.getElementById('deploy--solutionsList-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
        document.getElementById('deploy--versionCombo-arrow').onclick = () => {
          const list = document.getElementById('deploy--versionCombo-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
      </script>
    `);

    const cell = {
      deployment: 'pr-1-eic-1',
      eic: { solution: '', version: '8.48.99', namespaces: {}, servicesDeployment: 'x', gatewaysDeployment: 'y' },
      services: { postgres: {}, datastore: {} },
      files: {},
    };

    await assert.rejects(
      async () => await elmPages.deployEic(page, { clusterName: 'hcp-x', cell }),
      /EIC version 8\.48\.99 is not offered by ELM/
    );
    assert.equal(await page.locator('#deployed').innerText(), 'false');
  } finally { await page.close(); }
});

test('deploy_selects_solution', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const dir = await mkdtemp(join(tmpdir(), 'deploy-solution-test-'));
  const postgresCA = join(dir, 'postgres-ca.crt');
  const redisCA = join(dir, 'redis-ca.pem');
  await writeFile(postgresCA, 'fake-ca\n');
  await writeFile(redisCA, 'fake-ca\n');
  try {
    await page.setContent(`
      <button id="deploy-solution">Deploy Solution</button>
      <section id="solution-step" style="display: none">
        <div id="deploy--solutionsList-arrow" role="combobox" aria-label="Solution">
          <span class="selected">Edge Integration Cell (prod)</span>
          <div class="list" hidden><div>Edge Integration Cell (dev)</div><div>Edge Integration Cell (prod)</div></div>
        </div>
        <label>Deployment Name<input id="deployment-name"></label>
        <div id="deploy--versionCombo-arrow" role="combobox" aria-label="Version">
          <span class="selected">8.48.16</span>
        </div>
        <button id="step1">Next Step</button>
      </section>
      <section id="namespace-step" style="display: none">
        <div id="deploy--namespacesForm--Form--Grid">
          <label>Edge Integration Cell (main namespace)<input id="main-ns"></label>
          <label>Edge Security Artifact Secrets<input id="secrets-ns"></label>
          <label>Edge Local Authorization<input id="ela-ns"></label>
          <label>Default Virtual Host<input id="vhost"></label>
          <label>Default Virtual Host Key Alias<input id="key-alias"></label>
          <label><input type="checkbox" id="shared-fs">Enable shared file system</label>
          <label>Shared File System Storage<input id="storage-class"></label>
        </div>
        <button id="step2a">Next Step</button>
      </section>
      <section id="step2" style="display: none">
        <button id="step2-next">Next Step</button>
      </section>
      <section id="services-step" style="display: none">
        <label>Deployment Name<input id="services-deployment"></label>
        <label>Edge Integration Cell<input id="services-ns"></label>
        <div role="combobox" aria-label="Database Type"><span>PostgreSQL</span></div>
        <div role="combobox" aria-label="Datastore Type"><span>Redis</span></div>
        <label>PostgreSQL Hostname<input id="pg-host"></label>
        <label>PostgreSQL Port<input id="pg-port"></label>
        <label>PostgreSQL DB Name<input id="pg-db"></label>
        <label>PostgreSQL Username<input id="pg-user"></label>
        <label>PostgreSQL Password<input id="pg-pass" type="password"></label>
        <input type="file" id="pg-ca" role="button" title="Activate to Select a File" aria-label="Browse or drop a file">
        <label>Redis Addresses<input id="redis-addr"></label>
        <div role="combobox" aria-label="Redis Mode"><span>standalone</span></div>
        <label>Redis Password<input id="redis-pass" type="password"></label>
        <input type="file" id="redis-ca" role="button" title="Activate to Select a File" aria-label="Browse or drop a file">
        <label>Redis Server Name<input id="redis-server"></label>
        <button id="step3">Next Step</button>
      </section>
      <section id="gateways-step" style="display: none">
        <label>Deployment Name<input id="gateways-deployment"></label>
        <label>IstioGateways (main namespace)<input id="gateways-ns"></label>
        <div role="combobox" aria-label="Load Balancer Provider"><span>Other</span></div>
        <button id="step4">Next Step</button>
      </section>
      <section id="review-step" style="display: none">
        <button id="deploy" title="Default Action">Deploy</button>
      </section>
      <output id="deployed">false</output>
      <output id="solution-clicked">none</output>
      <script>
        const sections = ['solution-step', 'namespace-step', 'step2', 'services-step', 'gateways-step', 'review-step'];
        function showOnly(id) {
          sections.forEach(s => document.getElementById(s).style.display = 'none');
          document.getElementById(id).style.display = 'block';
        }
        document.getElementById('deploy-solution').onclick = () => showOnly('solution-step');
        document.getElementById('deploy--solutionsList-arrow').onclick = () => {
          const list = document.getElementById('deploy--solutionsList-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
        document.querySelectorAll('#deploy--solutionsList-arrow .list div').forEach(div => {
          div.onclick = () => {
            document.getElementById('solution-clicked').textContent = div.textContent;
            document.querySelector('#deploy--solutionsList-arrow .selected').textContent = div.textContent;
            document.getElementById('deploy--solutionsList-arrow').querySelector('.list').hidden = true;
          };
        });
        document.getElementById('step1').onclick = () => showOnly('namespace-step');
        document.getElementById('step2a').onclick = () => showOnly('step2');
        document.getElementById('step2-next').onclick = () => showOnly('services-step');
        document.getElementById('step3').onclick = () => showOnly('gateways-step');
        document.getElementById('step4').onclick = () => showOnly('review-step');
        document.getElementById('deploy').onclick = () => document.getElementById('deployed').textContent = 'true';
      </script>
    `);

    const cell = {
      deployment: 'pr-1-eic-1',
      eic: {
        solution: 'Edge Integration Cell (dev)',
        version: '',
        namespaces: { main: 'edge-icell-1', secrets: 'edge-icell-secrets-1', ela: 'edge-icell-ela-1', services: 'edge-icell-services-1', gateways: 'istio-gateways-1' },
        virtualHost: 'eic-1.apps.x',
        keyAlias: 'slv-ic',
        sharedFsStorageClass: 'nfs-rwx',
        servicesDeployment: 'pr-1-eic-1-services',
        gatewaysDeployment: 'pr-1-eic-1-gateways',
      },
      services: {
        postgres: { host: 'h', port: 'p', database: 'd', username: 'u', password: 'pw' },
        datastore: { type: 'redis', address: 'a', mode: 'standalone', password: 'pw', serverName: 's', username: '' },
      },
      files: { postgresCA, redisCA },
    };

    await elmPages.deployEic(page, { clusterName: 'hcp-x', cell });
    assert.equal(await page.locator('#solution-clicked').innerText(), 'Edge Integration Cell (dev)');
    assert.equal(await page.locator('#deployed').innerText(), 'true');
  } finally {
    await page.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('deploy_solution_not_offered_hands_over', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <button id="deploy-solution">Deploy Solution</button>
      <section id="solution-step" style="display: none">
        <div id="deploy--solutionsList-arrow" role="combobox" aria-label="Solution">
          <span class="selected">Edge Integration Cell (dev)</span>
          <div class="list" hidden><div>Edge Integration Cell (dev)</div></div>
        </div>
        <label>Deployment Name<input id="deployment-name"></label>
        <div id="deploy--versionCombo-arrow" role="combobox" aria-label="Version">
          <span class="selected">8.48.16</span>
        </div>
      </section>
      <output id="deployed">false</output>
      <script>
        document.getElementById('deploy-solution').onclick = () => {
          document.getElementById('solution-step').style.display = 'block';
        };
        document.getElementById('deploy--solutionsList-arrow').onclick = () => {
          const list = document.getElementById('deploy--solutionsList-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
      </script>
    `);

    const cell = {
      deployment: 'pr-1-eic-1',
      eic: { solution: 'Edge Integration Cell (prod)', version: '', namespaces: {}, servicesDeployment: 'x', gatewaysDeployment: 'y' },
      services: { postgres: {}, datastore: {} },
      files: {},
    };

    await assert.rejects(
      async () => await elmPages.deployEic(page, { clusterName: 'hcp-x', cell }),
      /Solution Edge Integration Cell \(prod\) is not offered by ELM/
    );
    assert.equal(await page.locator('#deployed').innerText(), 'false');
  } finally { await page.close(); }
});

test('deploy_empty_version_keeps_preselected', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const dir = await mkdtemp(join(tmpdir(), 'deploy-version-test-'));
  const postgresCA = join(dir, 'postgres-ca.crt');
  const redisCA = join(dir, 'redis-ca.pem');
  await writeFile(postgresCA, 'fake-ca\n');
  await writeFile(redisCA, 'fake-ca\n');
  try {
    await page.setContent(`
      <button id="deploy-solution">Deploy Solution</button>
      <section id="solution-step" style="display: none">
        <div id="deploy--solutionsList-arrow" role="combobox" aria-label="Solution">
          <span class="selected">Edge Integration Cell (dev)</span>
          <div class="list" hidden><div>Edge Integration Cell (dev)</div></div>
        </div>
        <label>Deployment Name<input id="deployment-name"></label>
        <div id="deploy--versionCombo-arrow" role="combobox" aria-label="Version">
          <span class="selected">8.48.16</span>
        </div>
        <button id="step1">Next Step</button>
      </section>
      <section id="namespace-step" style="display: none">
        <div id="deploy--namespacesForm--Form--Grid">
          <label>Edge Integration Cell (main namespace)<input id="main-ns"></label>
          <label>Edge Security Artifact Secrets<input id="secrets-ns"></label>
          <label>Edge Local Authorization<input id="ela-ns"></label>
          <label>Default Virtual Host<input id="vhost"></label>
          <label>Default Virtual Host Key Alias<input id="key-alias"></label>
          <label><input type="checkbox" id="shared-fs">Enable shared file system</label>
          <label>Shared File System Storage<input id="storage-class"></label>
        </div>
        <button id="step2a">Next Step</button>
      </section>
      <section id="step2" style="display: none">
        <button id="step2-next">Next Step</button>
      </section>
      <section id="services-step" style="display: none">
        <label>Deployment Name<input id="services-deployment"></label>
        <label>Edge Integration Cell<input id="services-ns"></label>
        <div role="combobox" aria-label="Database Type"><span>PostgreSQL</span></div>
        <div role="combobox" aria-label="Datastore Type"><span>Redis</span></div>
        <label>PostgreSQL Hostname<input id="pg-host"></label>
        <label>PostgreSQL Port<input id="pg-port"></label>
        <label>PostgreSQL DB Name<input id="pg-db"></label>
        <label>PostgreSQL Username<input id="pg-user"></label>
        <label>PostgreSQL Password<input id="pg-pass" type="password"></label>
        <input type="file" id="pg-ca" role="button" title="Activate to Select a File" aria-label="Browse or drop a file">
        <label>Redis Addresses<input id="redis-addr"></label>
        <div role="combobox" aria-label="Redis Mode"><span>standalone</span></div>
        <label>Redis Password<input id="redis-pass" type="password"></label>
        <input type="file" id="redis-ca" role="button" title="Activate to Select a File" aria-label="Browse or drop a file">
        <label>Redis Server Name<input id="redis-server"></label>
        <button id="step3">Next Step</button>
      </section>
      <section id="gateways-step" style="display: none">
        <label>Deployment Name<input id="gateways-deployment"></label>
        <label>IstioGateways (main namespace)<input id="gateways-ns"></label>
        <div role="combobox" aria-label="Load Balancer Provider"><span>Other</span></div>
        <button id="step4">Next Step</button>
      </section>
      <section id="review-step" style="display: none">
        <button id="deploy" title="Default Action">Deploy</button>
      </section>
      <output id="deployed">false</output>
      <script>
        const sections = ['solution-step', 'namespace-step', 'step2', 'services-step', 'gateways-step', 'review-step'];
        function showOnly(id) {
          sections.forEach(s => document.getElementById(s).style.display = 'none');
          document.getElementById(id).style.display = 'block';
        }
        document.getElementById('deploy-solution').onclick = () => showOnly('solution-step');
        document.getElementById('deploy--solutionsList-arrow').onclick = () => {
          const list = document.getElementById('deploy--solutionsList-arrow').querySelector('.list');
          list.hidden = !list.hidden;
        };
        document.getElementById('step1').onclick = () => showOnly('namespace-step');
        document.getElementById('step2a').onclick = () => showOnly('step2');
        document.getElementById('step2-next').onclick = () => showOnly('services-step');
        document.getElementById('step3').onclick = () => showOnly('gateways-step');
        document.getElementById('step4').onclick = () => showOnly('review-step');
        document.getElementById('deploy').onclick = () => document.getElementById('deployed').textContent = 'true';
      </script>
    `);

    const cell = {
      deployment: 'pr-1-eic-1',
      eic: {
        solution: '',
        version: '',
        namespaces: { main: 'edge-icell-1', secrets: 'edge-icell-secrets-1', ela: 'edge-icell-ela-1', services: 'edge-icell-services-1', gateways: 'istio-gateways-1' },
        virtualHost: 'eic-1.apps.x',
        keyAlias: 'slv-ic',
        sharedFsStorageClass: 'nfs-rwx',
        servicesDeployment: 'pr-1-eic-1-services',
        gatewaysDeployment: 'pr-1-eic-1-gateways',
      },
      services: {
        postgres: { host: 'h', port: 'p', database: 'd', username: 'u', password: 'pw' },
        datastore: { type: 'redis', address: 'a', mode: 'standalone', password: 'pw', serverName: 's', username: '' },
      },
      files: { postgresCA, redisCA },
    };

    await elmPages.deployEic(page, { clusterName: 'hcp-x', cell });
    assert.equal(await page.locator('#deployed').innerText(), 'true');
  } finally {
    await page.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('eic_zip_downloaded', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  const dir = await mkdtemp(join(tmpdir(), 'eic-zip-test-'));
  const expectedContent = 'fake-eic-zip-content-12345';
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div id="row"><span>pr-1-eic-1</span> <span>8.48.16</span></div>
      </div>
      <button id="operations-label" aria-label="Operations" style="display: none">Operations</button>
      <dialog id="operations-menu" style="display: none">
        <div id="download-option">Download Kubernetes Resources</div>
      </dialog>
      <dialog id="download-dialog" style="display: none">
        <button id="download-action" title="Default Action">Download</button>
      </dialog>
      <script>
        document.getElementById('row').onclick = () => {
          document.getElementById('operations-label').style.display = 'block';
        };
        document.getElementById('operations-label').onclick = () => {
          document.getElementById('operations-menu').style.display = 'block';
        };
        document.getElementById('download-option').onclick = () => {
          document.getElementById('operations-menu').style.display = 'none';
          document.getElementById('download-dialog').style.display = 'block';
        };
        document.getElementById('download-action').onclick = () => {
          const content = 'fake-eic-zip-content-12345';
          const base64 = btoa(content);
          const a = document.createElement('a');
          a.href = 'data:application/zip;base64,' + base64;
          a.download = 'restricted-resources-pr-1-eic-1-8.48.16.zip';
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
        };
      </script>
    `);

    const zipPath = await elmPages.downloadEicZip(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1', dir });

    assert.match(zipPath, /restricted-resources-pr-1-eic-1-.*\.zip$/);
    const fileContent = await readFile(zipPath, 'utf8');
    assert.equal(fileContent, expectedContent);
  } finally {
    await page.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('resume_clicks_resume_operation', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div id="row">Initial Object Status <span>pr-1-eic-1</span> <span>8.48.16</span></div>
      </div>
      <button id="operations-label" aria-label="Operations" style="display: none">Operations</button>
      <dialog id="operations-menu" style="display: none">
        <div id="resume-option">Resume Operation</div>
      </dialog>
      <dialog id="resume-dialog" style="display: none">
        <button id="resume-btn">Resume</button>
      </dialog>
      <output id="resumed">false</output>
      <script>
        document.getElementById('row').onclick = () => {
          document.getElementById('operations-label').style.display = 'block';
        };
        document.getElementById('operations-label').onclick = () => {
          document.getElementById('operations-menu').style.display = 'block';
        };
        document.getElementById('resume-option').onclick = () => {
          document.getElementById('operations-menu').style.display = 'none';
          document.getElementById('resume-dialog').style.display = 'block';
        };
        document.getElementById('resume-btn').onclick = () => document.getElementById('resumed').textContent = 'true';
      </script>
    `);

    await elmPages.resumeEicDeployment(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1' });
    assert.equal(await page.locator('#resumed').innerText(), 'true');
  } finally { await page.close(); }
});

test('status_parses_row', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div>Edge Lifecycle Management 1.65.0</div>
        <div>Running Object Status Entry successfully validated pr-1-eic-1 8.48.16 Object Status Operations Navigation Last Operation Status : Successful</div>
      </div>
    `);

    const status = await elmPages.eicDeploymentStatus(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1' });
    assert.deepEqual(status, { operation: 'Successful', status: 'Running', version: '8.48.16' });
  } finally { await page.close(); }
});

test('status_null_when_absent', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div>Edge Lifecycle Management 1.65.0</div>
      </div>
    `);

    const status = await elmPages.eicDeploymentStatus(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1' });
    assert.equal(status, null);
  } finally { await page.close(); }
});

test('upgrade_selects_exact_version', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div id="row"><span>pr-1-eic-1</span> <span>8.48.16</span></div>
      </div>
      <button id="operations-label" aria-label="Operations" style="display: none">Operations</button>
      <dialog id="operations-menu" style="display: none">
        <div id="upgrade-option">Upgrade</div>
      </dialog>
      <section id="upgrade-wizard" style="display: none">
        <div id="upgrade--versionsListUpgrade-list">
          <div>8.49.11</div>
          <div>8.49.10</div>
        </div>
        <button id="step1">Next Step</button>
        <button id="step2" style="display: none">Next Step</button>
        <button id="step3" style="display: none">Next Step</button>
        <button id="step4" style="display: none">Next Step</button>
        <button id="upgrade-btn" style="display: none">Upgrade</button>
      </section>
      <output id="upgraded">false</output>
      <output id="version-clicked"></output>
      <script>
        document.getElementById('row').onclick = () => {
          document.getElementById('operations-label').style.display = 'block';
        };
        document.getElementById('operations-label').onclick = () => {
          document.getElementById('operations-menu').style.display = 'block';
        };
        document.getElementById('upgrade-option').onclick = () => {
          document.getElementById('operations-menu').style.display = 'none';
          document.getElementById('upgrade-wizard').style.display = 'block';
        };
        document.querySelectorAll('#upgrade--versionsListUpgrade-list div').forEach(div => {
          div.onclick = () => {
            document.getElementById('version-clicked').textContent = div.textContent;
          };
        });
        document.getElementById('step1').onclick = () => {
          document.getElementById('step1').style.display = 'none';
          document.getElementById('step2').style.display = 'block';
        };
        document.getElementById('step2').onclick = () => {
          document.getElementById('step2').style.display = 'none';
          document.getElementById('step3').style.display = 'block';
        };
        document.getElementById('step3').onclick = () => {
          document.getElementById('step3').style.display = 'none';
          document.getElementById('step4').style.display = 'block';
        };
        document.getElementById('step4').onclick = () => {
          document.getElementById('step4').style.display = 'none';
          document.getElementById('upgrade-btn').style.display = 'block';
        };
        document.getElementById('upgrade-btn').onclick = () => document.getElementById('upgraded').textContent = 'true';
      </script>
    `);

    await elmPages.upgradeEic(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1', version: '8.49.11' });
    assert.equal(await page.locator('#version-clicked').innerText(), '8.49.11');
    assert.equal(await page.locator('#upgraded').innerText(), 'true');
  } finally { await page.close(); }
});

test('upgrade_version_not_offered_hands_over', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div id="row"><span>pr-1-eic-1</span> <span>8.48.16</span></div>
      </div>
      <button id="operations-label" aria-label="Operations" style="display: none">Operations</button>
      <dialog id="operations-menu" style="display: none">
        <div id="upgrade-option">Upgrade</div>
      </dialog>
      <section id="upgrade-wizard" style="display: none">
        <div id="upgrade--versionsListUpgrade-list">
          <div>8.49.11</div>
          <div>8.49.10</div>
        </div>
      </section>
      <output id="upgraded">false</output>
      <script>
        document.getElementById('row').onclick = () => {
          document.getElementById('operations-label').style.display = 'block';
        };
        document.getElementById('operations-label').onclick = () => {
          document.getElementById('operations-menu').style.display = 'block';
        };
        document.getElementById('upgrade-option').onclick = () => {
          document.getElementById('operations-menu').style.display = 'none';
          document.getElementById('upgrade-wizard').style.display = 'block';
        };
      </script>
    `);

    await assert.rejects(
      async () => await elmPages.upgradeEic(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1', version: '8.49.99' }),
      /EIC version 8\.49\.99 is not offered by ELM/
    );
    assert.equal(await page.locator('#upgraded').innerText(), 'false');
  } finally { await page.close(); }
});

test('delete_confirms_with_delete_not_cancel', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <div role="grid" aria-label="All Deployments">
        <div id="row"><span>pr-1-eic-1</span> <span>8.49.11</span></div>
      </div>
      <button id="operations-label" aria-label="Operations" style="display: none">Operations</button>
      <dialog id="operations-menu" style="display: none">
        <div id="delete-option">Delete</div>
      </dialog>
      <dialog id="confirm-dialog" style="display: none">
        <button id="delete-btn">Delete</button>
        <button id="cancel-btn">Cancel</button>
      </dialog>
      <output id="deleted">false</output>
      <output id="cancelled">false</output>
      <script>
        document.getElementById('row').onclick = () => {
          document.getElementById('operations-label').style.display = 'block';
        };
        document.getElementById('operations-label').onclick = () => {
          document.getElementById('operations-menu').style.display = 'block';
        };
        document.getElementById('delete-option').onclick = () => {
          document.getElementById('operations-menu').style.display = 'none';
          document.getElementById('confirm-dialog').style.display = 'block';
        };
        document.getElementById('delete-btn').onclick = () => document.getElementById('deleted').textContent = 'true';
        document.getElementById('cancel-btn').onclick = () => document.getElementById('cancelled').textContent = 'true';
      </script>
    `);

    await elmPages.deleteEicDeployment(page, { clusterName: 'hcp-x', deployment: 'pr-1-eic-1' });
    assert.equal(await page.locator('#deleted').innerText(), 'true');
    assert.equal(await page.locator('#cancelled').innerText(), 'false');
  } finally { await page.close(); }
});

test('remove_types_node_name', async () => {
  const page = await browser.newPage();
  page.setDefaultTimeout(3000);
  try {
    await page.setContent(`
      <button id="remove-header">Remove</button>
      <dialog id="confirm-dialog" style="display: none">
        <div>To confirm the removal of the Edge Node</div>
        <label>Edge Node Name<input id="node-name"></label>
        <button id="remove-btn" title="Default Action">Remove</button>
      </dialog>
      <output id="removed">false</output>
      <script>
        document.getElementById('remove-header').onclick = () => {
          document.getElementById('confirm-dialog').style.display = 'block';
        };
        document.getElementById('remove-btn').onclick = () => document.getElementById('removed').textContent = 'true';
      </script>
    `);

    await elmPages.removeEdgeNode(page, { clusterName: 'hcp-x' });
    assert.equal(await page.locator('#node-name').inputValue(), 'hcp-x');
    assert.equal(await page.locator('#removed').innerText(), 'true');
  } finally { await page.close(); }
});
