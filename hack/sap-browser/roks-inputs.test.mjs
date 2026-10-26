// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { loadRoksInputs, loadRestrictedKubeconfig } from './roks-inputs.mjs';

const encoded = (values) => Object.fromEntries(Object.entries(values).map(([key, value]) =>
  [key, Buffer.from(value).toString('base64')]));

function roksResources(cluster = 'c1') {
  return {
    [`pipelinerun/run-1`]: {
      metadata: { uid: 'run-uid' },
      spec: {
        pipelineRef: { name: 'roks-eic-full-test-pipeline' },
        params: [{ name: 'clusterName', value: cluster }],
      },
      status: {
        childReferences: [
          { name: 'validate-task', kind: 'TaskRun', pipelineTaskName: 'validate-and-get-access' },
          { name: 'registry-task', kind: 'TaskRun', pipelineTaskName: 'registry-access' },
        ],
      },
    },
    [`taskrun/validate-task`]: {
      metadata: { ownerReferences: [{ uid: 'run-uid' }] },
      status: { conditions: [{ type: 'Succeeded', status: 'True' }] },
    },
    [`taskrun/registry-task`]: {
      metadata: { ownerReferences: [{ uid: 'run-uid' }] },
      status: { conditions: [{ type: 'Succeeded', status: 'True' }] },
    },
    [`secret/eic-credentials-roks-${cluster}`]: {
      data: encoded({
        'postgres-host': 'db.example.test',
        'postgres-port': '5432',
        'postgres-database': 'edgedb',
        'postgres-username': 'edgedb',
        'postgres-ca': 'test-postgres-ca',
        'redis-host': 'redis.example.test',
        'redis-port': '6379',
        'redis-username': 'default',
        'redis-password': 'test-redis-password',
        'redis-ca': 'test-redis-ca',
        'kubeconfig': 'ADMIN-KUBECONFIG-MUST-NOT-BE-READ',
      }),
    },
    [`secret/eic-registry-roks-${cluster}`]: {
      data: encoded({
        'server': 'us.icr.io',
        'namespace': 'test-namespace',
        'username': 'iamapikey',
        'password': 'test-registry-password',
      }),
    },
    [`secret/edgelm-kubeconfig-generated-${cluster}`]: {
      data: encoded({ 'kubeconfig': 'RESTRICTED-KUBECONFIG' }),
    },
  };
}

const reader = (objects) => async (kind, name) => {
  const key = `${kind}/${name}`;
  if (!objects[key]) throw new Error(`Unexpected read: ${key}`);
  return objects[key];
};

test('maps_roks_keys', async () => {
  const objects = roksResources('c1');
  const inputs = await loadRoksInputs(reader(objects), 'run-1', {
    expectedRunUID: 'run-uid',
    expectedClusterName: 'c1',
    postgresPassword: 'test-postgres-password',
  });

  assert.equal(inputs.clusterName, 'c1');
  assert.equal(inputs.pipelineRun, 'run-1');
  assert.equal(inputs.postgres.host, 'db.example.test');
  assert.equal(inputs.postgres.port, '5432');
  assert.equal(inputs.postgres.database, 'edgedb');
  assert.equal(inputs.postgres.username, 'edgedb');
  assert.equal(inputs.postgres.password, 'test-postgres-password');
  assert.equal(inputs.redis.host, 'redis.example.test');
  assert.equal(inputs.redis.port, '6379');
  assert.equal(inputs.redis.username, 'default');
  assert.equal(inputs.redis.password, 'test-redis-password');
  assert.equal(inputs.registry.server, 'us.icr.io');
  assert.equal(inputs.registry.namespace, 'test-namespace');
  assert.equal(inputs.registry.username, 'iamapikey');
  assert.equal(inputs.registry.password, 'test-registry-password');
  assert.equal(inputs.attachments.postgresCA, 'test-postgres-ca');
  assert.equal(inputs.attachments.redisCA, 'test-redis-ca');
});

test('never_reads_admin_kubeconfig', async () => {
  const objects = roksResources('c1');
  const inputs = await loadRoksInputs(reader(objects), 'run-1', {
    expectedRunUID: 'run-uid',
    expectedClusterName: 'c1',
    postgresPassword: 'test-postgres-password',
  });

  // Admin kubeconfig should never appear in the result
  const serialized = JSON.stringify(inputs);
  assert.ok(!serialized.includes('ADMIN-KUBECONFIG-MUST-NOT-BE-READ'));
});

test('rejects_other_pipeline', async () => {
  const objects = roksResources('c1');
  objects['pipelinerun/run-1'].spec.pipelineRef.name = 'different-pipeline';

  await assert.rejects(
    loadRoksInputs(reader(objects), 'run-1', { postgresPassword: 'test-pass' }),
    /roks-eic-full-test-pipeline/
  );
});

test('rejects_unfinished_registry_access', async () => {
  const objects = roksResources('c1');
  objects['taskrun/registry-task'].status.conditions[0].status = 'False';

  await assert.rejects(
    loadRoksInputs(reader(objects), 'run-1', { postgresPassword: 'test-pass' }),
    /registry-access.*succeed/i
  );
});

test('requires_postgres_password', async () => {
  const objects = roksResources('c1');

  await assert.rejects(
    loadRoksInputs(reader(objects), 'run-1', {
      expectedRunUID: 'run-uid',
      expectedClusterName: 'c1',
      // Missing postgresPassword
    }),
    /postgres.*password/i
  );
});

test('restricted_kubeconfig_only_from_generated_secret', async () => {
  const reads = [];
  const trackingReader = async (kind, name) => {
    reads.push(`${kind}/${name}`);
    const objects = roksResources('c1');
    const key = `${kind}/${name}`;
    if (!objects[key]) throw new Error(`Unexpected read: ${key}`);
    return objects[key];
  };

  const kubeconfig = await loadRestrictedKubeconfig(trackingReader, 'c1');

  assert.equal(kubeconfig, 'RESTRICTED-KUBECONFIG');
  assert.ok(reads.includes('secret/edgelm-kubeconfig-generated-c1'));
  // Should only read the generated secret, not the admin one
  assert.ok(!reads.includes('secret/eic-credentials-roks-c1'));
});
