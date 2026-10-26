// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { inClusterClient } from './cluster-reader.mjs';
import { SetupError } from './inputs.mjs';

test('route_paths_and_merge_patch', async () => {
  const requests = [];
  const transport = async (method, path, body, headers) => {
    requests.push({ method, path, body, headers });
    return { status: 200, json: async () => ({ metadata: { name: 'test-route' } }) };
  };
  const client = inClusterClient('test-namespace', { transport });

  // Test route path uses OpenShift route API
  await client.get('route', 'my-route');
  assert.equal(requests[0].path, '/apis/route.openshift.io/v1/namespaces/test-namespace/routes/my-route');

  // Test patch uses merge-patch+json content type
  await client.patch('service', 'my-service', { spec: { type: 'LoadBalancer' } });
  const patchReq = requests.find(r => r.method === 'PATCH');
  assert.ok(patchReq);
  assert.equal(patchReq.headers['Content-Type'], 'application/merge-patch+json');
  assert.equal(patchReq.path, '/api/v1/namespaces/test-namespace/services/my-service');
});

test('remove_tolerates_404', async () => {
  const transport = async () => ({ status: 404, json: async () => ({}) });
  const client = inClusterClient('test-namespace', { transport });

  // Should not throw on 404
  await client.remove('service', 'nonexistent');
});

test('errors_hide_bodies', async () => {
  const transport = async () => ({
    status: 500,
    json: async () => ({ message: 'SECRET-PASSWORD-VALUE in error body' })
  });
  const client = inClusterClient('test-namespace', { transport });

  await assert.rejects(
    client.get('secret', 'test-secret'),
    (err) => {
      // Error should not contain the response body with secrets
      assert.ok(!err.message.includes('SECRET-PASSWORD-VALUE'));
      return true;
    }
  );
});

test('create_posts_to_correct_paths', async () => {
  const requests = [];
  const transport = async (method, path, body, headers) => {
    requests.push({ method, path, body, headers });
    return { status: 201, json: async () => ({ metadata: { name: 'created' } }) };
  };
  const client = inClusterClient('test-namespace', { transport });

  // Test service create
  await client.create('service', { metadata: { name: 'my-service' } });
  const serviceReq = requests.find(r => r.path.includes('services'));
  assert.equal(serviceReq.method, 'POST');
  assert.equal(serviceReq.path, '/api/v1/namespaces/test-namespace/services');
  assert.equal(serviceReq.headers['Content-Type'], 'application/json');

  // Test route create
  await client.create('route', { metadata: { name: 'my-route' } });
  const routeReq = requests.find(r => r.path.includes('routes'));
  assert.equal(routeReq.method, 'POST');
  assert.equal(routeReq.path, '/apis/route.openshift.io/v1/namespaces/test-namespace/routes');
  assert.equal(routeReq.headers['Content-Type'], 'application/json');
});

test('patch_uses_correct_content_type', async () => {
  const requests = [];
  const transport = async (method, path, body, headers) => {
    requests.push({ method, path, body, headers });
    return { status: 200, json: async () => ({ metadata: { name: 'patched' } }) };
  };
  const client = inClusterClient('test-namespace', { transport });

  await client.patch('serviceaccount', 'my-sa', { metadata: { labels: { foo: 'bar' } } });
  const patchReq = requests[0];
  assert.equal(patchReq.method, 'PATCH');
  assert.equal(patchReq.path, '/api/v1/namespaces/test-namespace/serviceaccounts/my-sa');
  assert.equal(patchReq.headers['Content-Type'], 'application/merge-patch+json');
});

test('create_409_returns_setup_error_with_exists_code', async () => {
  const transport = async () => ({
    status: 409,
    json: async () => ({ message: 'AlreadyExists: secret-data-here' })
  });
  const client = inClusterClient('test-namespace', { transport });

  await assert.rejects(
    client.create('service', { metadata: { name: 'existing' } }),
    (err) => {
      assert.ok(err instanceof SetupError);
      assert.equal(err.code, 'exists');
      // Should not contain response body
      assert.ok(!err.message.includes('secret-data-here'));
      return true;
    }
  );
});
