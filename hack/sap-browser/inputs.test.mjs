// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmod, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeSecret, loadInputs, readPreparedInputs, serviceInputs, withPrivateFiles, writePreparedInputs } from './inputs.mjs';
import { optionsFor } from './cli.mjs';

const data = {
  'postgres-host': 'db.example.test', 'postgres-port': '5432', 'postgres-dbname': 'edgedb',
  'postgres-user': 'edgedb', 'postgres-password': 'test-db-password',
  'postgres-tls-root-cert': 'test-postgres-ca',
  'redis-address': 'redis.example.test:6379', 'redis-password': 'test-cache-password',
  'redis-server-name': 'redis.example.test', 'redis-tls-cert': 'test-redis-ca',
  'valkey-address': 'valkey.example.test:6379', 'valkey-password': 'test-valkey-password',
  'valkey-server-name': 'valkey.example.test', 'valkey-mode': 'cluster',
  'valkey-tls-cert': 'test-valkey-ca', kubeconfig: 'test-restricted-kubeconfig',
};
const encoded = (values) => Object.fromEntries(Object.entries(values).map(([key, value]) =>
  [key, Buffer.from(value).toString('base64')]));

function resources(datastore = 'redis') {
  return {
    'pipelinerun/run-1': {
      metadata: { uid: 'run-uid' },
      spec: { pipelineRef: { name: 'hcp-ossm3-validation-pipeline' }, params: [
        { name: 'hostedClusterName', value: 'hcp-demo' }, { name: 'datastoreType', value: datastore },
      ] },
      status: { childReferences: [{ name: 'accesses-1', kind: 'TaskRun', pipelineTaskName: 'get-all-accesses' }] },
    },
    'taskrun/accesses-1': {
      metadata: { ownerReferences: [{ uid: 'run-uid' }] },
      status: { startTime: '2026-10-22T10:00:00Z', completionTime: '2026-10-22T10:05:00Z',
        conditions: [{ type: 'Succeeded', status: 'True' }] },
    },
    'secret/eic-credentials-hcp-hcp-demo': {
      metadata: { creationTimestamp: '2026-10-22T10:04:00Z' },
      data: encoded({ ...data, 'valkey-mode': datastore === 'valkey-standalone' ? 'standalone' : 'cluster' }),
    },
    'secret/edgelm-kubeconfig-generated-hcp-demo': { data: encoded({ kubeconfig: 'fallback-restricted' }) },
  };
}
const reader = (objects) => async (kind, name) => {
  assert.ok(objects[`${kind}/${name}`], `Unexpected read: ${kind}/${name}`);
  return objects[`${kind}/${name}`];
};

test('reads the selected run, including Redis and both Valkey modes', async () => {
  for (const type of ['redis', 'valkey-standalone', 'valkey-cluster']) {
    const inputs = await loadInputs(reader(resources(type)), 'run-1');
    assert.equal(inputs.clusterName, 'hcp-demo');
    assert.equal(inputs.datastore.type, type);
    assert.equal(inputs.datastore.mode, type === 'valkey-cluster' ? 'cluster' : 'standalone');
    assert.equal(inputs.postgres.password, data['postgres-password']);
    assert.equal(inputs.attachments.datastoreCA, type === 'redis' ? 'test-redis-ca' : 'test-valkey-ca');
    assert.equal(inputs.attachments.kubeconfig, 'test-restricted-kubeconfig');
  }
});

test('uses only the dedicated restricted kubeconfig as fallback', async () => {
  const objects = resources();
  delete objects['secret/eic-credentials-hcp-hcp-demo'].data.kubeconfig;
  const inputs = await loadInputs(reader(objects), 'run-1');
  assert.equal(inputs.attachments.kubeconfig, 'fallback-restricted');
});

test('pipeline runner rejects the wrong run UID or cluster before reading credentials', async () => {
  const objects = resources();
  const onlyRun = reader({ 'pipelinerun/run-1': objects['pipelinerun/run-1'] });
  await assert.rejects(loadInputs(onlyRun, 'run-1', { expectedRunUID: 'another-uid' }), /UID does not match/);
  await assert.rejects(loadInputs(onlyRun, 'run-1', { expectedClusterName: 'another-cluster' }), /Cluster name does not match/);
  const inputs = await loadInputs(reader(objects), 'run-1', { expectedRunUID: 'run-uid', expectedClusterName: 'hcp-demo' });
  assert.equal(inputs.clusterName, 'hcp-demo');
  objects['secret/eic-credentials-hcp-hcp-demo'].data.kubeconfig = Buffer.from('N/A').toString('base64');
  await assert.rejects(loadInputs(reader(objects), 'run-1'), /kubeconfig/);
});

test('rejects a failed task or a task owned by another run before reading secrets', async () => {
  for (const change of [
    (task) => { task.status.conditions[0].status = 'False'; },
    (task) => { task.metadata.ownerReferences[0].uid = 'another-run'; },
  ]) {
    const objects = resources();
    change(objects['taskrun/accesses-1']);
    delete objects['secret/eic-credentials-hcp-hcp-demo'];
    await assert.rejects(loadInputs(reader(objects), 'run-1'), /must succeed/);
  }
});

test('rejects stale or replaced shared credentials', async () => {
  for (const timestamp of ['2026-10-21T10:00:00Z', '2026-10-23T10:00:00Z', undefined]) {
    const objects = resources();
    objects['secret/eic-credentials-hcp-hcp-demo'].metadata.creationTimestamp = timestamp;
    await assert.rejects(loadInputs(reader(objects), 'run-1'), /time window/);
  }
});

test('rejects incomplete credentials without echoing secret values', () => {
  assert.throws(() => serviceInputs({ ...data, 'postgres-password': 'N/A' }, 'redis'), /postgres-password/);
  assert.throws(() => serviceInputs({ ...data, 'redis-address': 'N/A:6379' }, 'redis'), /redis-address/);
  assert.throws(() => decodeSecret({ data: { password: 'not base64!' } }), /Invalid base64 in Secret field: password/);
});

test('creates private attachments and removes them on success and failure', async () => {
  const inputs = await loadInputs(reader(resources()), 'run-1');
  for (const fail of [false, true]) {
    let saved;
    const work = withPrivateFiles(inputs, async (files) => {
      saved = files.kubeconfig;
      assert.equal((await stat(saved)).mode & 0o777, 0o600);
      assert.equal((await stat(new URL('.', `file://${saved}`))).mode & 0o777, 0o700);
      assert.equal(await readFile(saved, 'utf8'), inputs.attachments.kubeconfig);
      if (fail) throw new Error('Simulated browser failure');
    });
    if (fail) await assert.rejects(work, /Simulated browser failure/);
    else await work;
    await assert.rejects(stat(saved), { code: 'ENOENT' });
  }
});

test('requires explicit target context and tenant, with no insecure URL fallback', () => {
  assert.throws(() => optionsFor(['inspect', '--url', 'http://example.test']), /HTTPS/);
  assert.throws(() => optionsFor(['inspect', '--url', 'https://user:pass@example.test']), /credentials/);
  assert.throws(() => optionsFor(['review-registration', '--url', 'https://example.test']), /--context/);
  assert.throws(() => optionsFor(['inspect', '--url', 'https://example.test', '--login-minutes', 'NaN']), /login-minutes/);
  assert.equal(optionsFor(['inspect', '--url', 'https://example.test']).mode, 'inspect');
});

test('allows a name-only registration preview without bypassing run credential checks', () => {
  const preview = ['review-registration', '--url', 'https://example.test', '--cluster', 'test-cluster'];
  assert.equal(optionsFor(preview).cluster, 'test-cluster');
  assert.throws(() => optionsFor(['run', ...preview.slice(1)]), /review-only/);
  assert.throws(() => optionsFor([...preview, '--context', 'another-cluster']), /review-only/);
  assert.throws(() => optionsFor([...preview.slice(0, -1), '../invalid']), /valid lowercase/);
});

test('collects and loads private inputs without a browser or a second Kubernetes connection', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'sap-inputs-test-'));
  try {
    const inputs = await loadInputs(reader(resources('valkey-cluster')), 'run-1');
    const output = join(folder, 'collected');
    const filename = await writePreparedInputs(inputs, output);
    const prepared = await readPreparedInputs(filename);
    assert.deepEqual(prepared.inputs, inputs);
    assert.ok(Number.isFinite(Date.parse(prepared.preparedAt)));
    if (process.platform !== 'win32') {
      assert.equal((await stat(output)).mode & 0o777, 0o700);
      assert.equal((await stat(filename)).mode & 0o777, 0o600);
    }
    await assert.rejects(writePreparedInputs(inputs, output), /Choose a new/);
    assert.deepEqual((await readPreparedInputs(filename)).inputs, inputs);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test('rejects malformed, incomplete and publicly readable prepared credentials', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'sap-inputs-test-'));
  try {
    const inputs = await loadInputs(reader(resources()), 'run-1');
    const filename = await writePreparedInputs(inputs, join(folder, 'collected'));
    if (process.platform !== 'win32') {
      await chmod(filename, 0o644);
      await assert.rejects(readPreparedInputs(filename), /0600/);
      await chmod(filename, 0o600);
    }
    await writeFile(filename, 'invalid-json-containing-a-secret');
    await assert.rejects(readPreparedInputs(filename), {
      message: 'Cannot read the prepared-inputs JSON file.',
    });
    delete inputs.postgres.password;
    await writeFile(filename, JSON.stringify({ version: 1, preparedAt: new Date().toISOString(), inputs }));
    await assert.rejects(readPreparedInputs(filename), /missing or unavailable: password/);
    await writeFile(filename, JSON.stringify({ version: 99 }));
    await assert.rejects(readPreparedInputs(filename), /Unsupported or invalid/);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test('separates SAP-network collection options from browser-only input options', () => {
  const collect = ['prepare-inputs', '--context', 'sap', '--namespace', 'pipelines', '--pipeline-run', 'run-1', '--output', 'private-output'];
  assert.equal(optionsFor(collect).mode, 'prepare-inputs');
  assert.throws(() => optionsFor([...collect, '--url', 'https://example.test']), /without --url/);
  assert.throws(() => optionsFor(collect.slice(0, -2)), /requires --output/);
  const offline = ['run', '--url', 'https://example.test', '--inputs', 'inputs.json', '--flow', 'flow.mjs'];
  assert.equal(optionsFor(offline).inputs, 'inputs.json');
  assert.throws(() => optionsFor([...offline, '--context', 'sap']), /alternative/);
  assert.throws(() => optionsFor(['inspect', '--url', 'https://example.test', '--inputs', 'inputs.json']), /alternative/);
});
