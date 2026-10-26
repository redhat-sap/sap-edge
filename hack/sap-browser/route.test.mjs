// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { routeName, openRoute } from './route.mjs';
import { SetupError } from './inputs.mjs';

test('routeName', () => {
  assert.equal(routeName('my-cluster'), 'roks-sap-browser-my-cluster');
  assert.equal(routeName('test'), 'roks-sap-browser-test');
});

test('creates_service_route_and_annotation', async () => {
  const requests = [];
  const fakeClient = {
    async create(kind, body) {
      requests.push({ action: 'create', kind, body });
      return { metadata: { name: body.metadata.name } };
    },
    async patch(kind, name, mergePatch) {
      requests.push({ action: 'patch', kind, name, mergePatch });
      return { metadata: { name } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        return {
          status: {
            ingress: [{ host: 'test-route.example.com' }],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove() {},
  };

  const { url, close } = await openRoute(fakeClient, {
    name: 'test-route',
    podName: 'test-pod',
    podUID: 'test-uid-12345',
    taskRunName: 'test-taskrun',
    serviceAccount: 'test-sa',
    port: 4180,
    timeoutMs: 5000,
    intervalMs: 100,
  });

  // Verify Service creation
  const serviceReq = requests.find(r => r.action === 'create' && r.kind === 'service');
  assert.ok(serviceReq, 'Service should be created');
  assert.deepEqual(serviceReq.body, {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name: 'test-route',
      ownerReferences: [{
        apiVersion: 'v1',
        kind: 'Pod',
        name: 'test-pod',
        uid: 'test-uid-12345',
      }],
    },
    spec: {
      selector: { 'tekton.dev/taskRun': 'test-taskrun' },
      ports: [{
        port: 4180,
        targetPort: 4180,
      }],
    },
  });

  // Verify Route creation
  const routeReq = requests.find(r => r.action === 'create' && r.kind === 'route');
  assert.ok(routeReq, 'Route should be created');
  assert.deepEqual(routeReq.body, {
    apiVersion: 'route.openshift.io/v1',
    kind: 'Route',
    metadata: {
      name: 'test-route',
      ownerReferences: [{
        apiVersion: 'v1',
        kind: 'Pod',
        name: 'test-pod',
        uid: 'test-uid-12345',
      }],
    },
    spec: {
      to: {
        kind: 'Service',
        name: 'test-route',
      },
      tls: {
        termination: 'edge',
        insecureEdgeTerminationPolicy: 'Redirect',
      },
    },
  });

  // Verify ServiceAccount annotation patch
  const saPatch = requests.find(r => r.action === 'patch' && r.kind === 'serviceaccount');
  assert.ok(saPatch, 'ServiceAccount should be patched');
  assert.equal(saPatch.name, 'test-sa');
  assert.deepEqual(saPatch.mergePatch, {
    metadata: {
      annotations: {
        'serviceaccounts.openshift.io/oauth-redirectreference.test-route': JSON.stringify({
          kind: 'OAuthRedirectReference',
          apiVersion: 'v1',
          reference: {
            kind: 'Route',
            name: 'test-route',
          },
        }),
      },
    },
  });

  assert.ok(url, 'URL should be returned');
  await close();
});

test('url_from_admitted_host', async () => {
  const fakeClient = {
    async create() {
      return { metadata: { name: 'test-route' } };
    },
    async patch() {
      return { metadata: { name: 'test-sa' } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        return {
          status: {
            ingress: [{ host: 'my-route.apps.cluster.example.com' }],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove() {},
  };

  const { url } = await openRoute(fakeClient, {
    name: 'test-route',
    podName: 'test-pod',
    podUID: 'test-uid-12345',
    taskRunName: 'test-taskrun',
    serviceAccount: 'test-sa',
    timeoutMs: 5000,
    intervalMs: 100,
  });

  assert.equal(
    url,
    'https://my-route.apps.cluster.example.com/vnc.html?autoconnect=1&resize=remote&path=websockify'
  );
});

test('recreates_stale_objects', async () => {
  const actions = [];
  const createCounts = { service: 0, route: 0 };
  const fakeClient = {
    async create(kind, body) {
      createCounts[kind]++;
      const attempt = createCounts[kind];
      actions.push({ action: 'create', kind, name: body.metadata.name, attempt });
      // First attempt for each kind fails with 409
      if (attempt === 1) {
        const err = new SetupError('Resource already exists.');
        err.code = 'exists';
        throw err;
      }
      return { metadata: { name: body.metadata.name } };
    },
    async patch() {
      actions.push({ action: 'patch' });
      return { metadata: { name: 'test-sa' } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        return {
          status: {
            ingress: [{ host: 'test-route.example.com' }],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove(kind, name) {
      actions.push({ action: 'remove', kind, name });
    },
  };

  const { url } = await openRoute(fakeClient, {
    name: 'test-route',
    podName: 'test-pod',
    podUID: 'test-uid-12345',
    taskRunName: 'test-taskrun',
    serviceAccount: 'test-sa',
    timeoutMs: 5000,
    intervalMs: 100,
  });

  // Should have removed and recreated on conflict for both service and route
  const serviceCreates = actions.filter(a => a.action === 'create' && a.kind === 'service');
  const routeCreates = actions.filter(a => a.action === 'create' && a.kind === 'route');
  const serviceRemove = actions.find(a => a.action === 'remove' && a.kind === 'service');
  const routeRemove = actions.find(a => a.action === 'remove' && a.kind === 'route');

  assert.equal(serviceCreates.length, 2, 'Service created twice (initial + retry)');
  assert.equal(routeCreates.length, 2, 'Route created twice (initial + retry)');
  assert.ok(serviceRemove, 'Stale service removed');
  assert.ok(routeRemove, 'Stale route removed');
  assert.ok(url);
});

test('close_removes_everything', async () => {
  const removals = [];
  const patches = [];
  const fakeClient = {
    async create() {
      return { metadata: { name: 'test-route' } };
    },
    async patch(kind, name, mergePatch) {
      patches.push({ kind, name, mergePatch });
      return { metadata: { name } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        return {
          status: {
            ingress: [{ host: 'test-route.example.com' }],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove(kind, name) {
      removals.push({ kind, name });
    },
  };

  const { close } = await openRoute(fakeClient, {
    name: 'test-route',
    podName: 'test-pod',
    podUID: 'test-uid-12345',
    taskRunName: 'test-taskrun',
    serviceAccount: 'test-sa',
    timeoutMs: 5000,
    intervalMs: 100,
  });

  await close();

  // Verify removals
  assert.ok(removals.find(r => r.kind === 'route' && r.name === 'test-route'));
  assert.ok(removals.find(r => r.kind === 'service' && r.name === 'test-route'));

  // Verify annotation removal (last patch to serviceaccount, after close)
  const saPatches = patches.filter(p => p.kind === 'serviceaccount' && p.name === 'test-sa');
  assert.equal(saPatches.length, 2, 'Two patches to serviceaccount (add then remove)');
  const annotationRemoval = saPatches[1];
  assert.deepEqual(annotationRemoval.mergePatch, {
    metadata: {
      annotations: {
        'serviceaccounts.openshift.io/oauth-redirectreference.test-route': null,
      },
    },
  });
});

test('close_never_throws', async () => {
  const fakeClient = {
    async create() {
      return { metadata: { name: 'test-route' } };
    },
    async patch() {
      return { metadata: { name: 'test-sa' } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        return {
          status: {
            ingress: [{ host: 'test-route.example.com' }],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove() {
      throw new Error('Network error during cleanup');
    },
  };

  const { close } = await openRoute(fakeClient, {
    name: 'test-route',
    podName: 'test-pod',
    podUID: 'test-uid-12345',
    taskRunName: 'test-taskrun',
    serviceAccount: 'test-sa',
    timeoutMs: 5000,
    intervalMs: 100,
  });

  // Should not throw even if remove fails
  await assert.doesNotReject(close);
});

test('times_out_without_host', async () => {
  const fakeClient = {
    async create() {
      return { metadata: { name: 'test-route' } };
    },
    async patch() {
      return { metadata: { name: 'test-sa' } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        // Route never gets admitted (no host)
        return {
          status: {
            ingress: [],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove() {},
  };

  await assert.rejects(
    openRoute(fakeClient, {
      name: 'test-route',
      podName: 'test-pod',
      podUID: 'test-uid-12345',
      taskRunName: 'test-taskrun',
      serviceAccount: 'test-sa',
      timeoutMs: 200,
      intervalMs: 50,
    }),
    (err) => {
      assert.ok(err instanceof SetupError);
      assert.ok(err.message.includes('timeout') || err.message.includes('admitted'));
      return true;
    }
  );
});

test('failure_cleans_up_on_timeout', async () => {
  const removals = [];
  const patches = [];
  const fakeClient = {
    async create() {
      return { metadata: { name: 'test-route' } };
    },
    async patch(kind, name, mergePatch) {
      patches.push({ kind, name, mergePatch });
      return { metadata: { name } };
    },
    async get(kind, name) {
      if (kind === 'route' && name === 'test-route') {
        // Route never gets admitted (no host)
        return {
          status: {
            ingress: [],
          },
        };
      }
      throw new Error('Unexpected get');
    },
    async remove(kind, name) {
      removals.push({ kind, name });
    },
  };

  await assert.rejects(
    openRoute(fakeClient, {
      name: 'test-route',
      podName: 'test-pod',
      podUID: 'test-uid-12345',
      taskRunName: 'test-taskrun',
      serviceAccount: 'test-sa',
      timeoutMs: 200,
      intervalMs: 50,
    }),
    (err) => {
      assert.ok(err instanceof SetupError);
      assert.ok(err.message.includes('timeout') || err.message.includes('admitted'));
      return true;
    }
  );

  // Verify cleanup happened
  assert.ok(removals.find(r => r.kind === 'route' && r.name === 'test-route'), 'Route removed on timeout');
  assert.ok(removals.find(r => r.kind === 'service' && r.name === 'test-route'), 'Service removed on timeout');

  // Verify annotation was removed (not left set)
  const annotationRemoval = patches.find(p =>
    p.kind === 'serviceaccount' &&
    p.name === 'test-sa' &&
    p.mergePatch.metadata.annotations['serviceaccounts.openshift.io/oauth-redirectreference.test-route'] === null
  );
  assert.ok(annotationRemoval, 'Annotation removed on timeout');
});

test('failure_cleans_up_when_route_create_fails', async () => {
  const removals = [];
  const patches = [];
  const fakeClient = {
    async create(kind, body) {
      if (kind === 'service') {
        return { metadata: { name: body.metadata.name } };
      }
      if (kind === 'route') {
        // Route create fails with non-'exists' error
        throw new SetupError('Quota exceeded for routes');
      }
      throw new Error('Unexpected create');
    },
    async patch(kind, name, mergePatch) {
      patches.push({ kind, name, mergePatch });
      return { metadata: { name } };
    },
    async get() {
      throw new Error('Should not get here');
    },
    async remove(kind, name) {
      removals.push({ kind, name });
    },
  };

  await assert.rejects(
    openRoute(fakeClient, {
      name: 'test-route',
      podName: 'test-pod',
      podUID: 'test-uid-12345',
      taskRunName: 'test-taskrun',
      serviceAccount: 'test-sa',
      timeoutMs: 5000,
      intervalMs: 100,
    }),
    (err) => {
      assert.ok(err instanceof SetupError);
      assert.ok(err.message.includes('Quota exceeded'));
      return true;
    }
  );

  // Verify Service was removed (created before Route failed)
  assert.ok(removals.find(r => r.kind === 'service' && r.name === 'test-route'), 'Service removed after Route create failure');

  // Annotation should not be left set (patch to null should be attempted, even if it wasn't set)
  // The cleanup tries to remove it regardless
  const hasAnnotationRemoval = patches.some(p =>
    p.kind === 'serviceaccount' &&
    p.name === 'test-sa' &&
    p.mergePatch.metadata.annotations['serviceaccounts.openshift.io/oauth-redirectreference.test-route'] === null
  );
  assert.ok(hasAnnotationRemoval, 'Annotation cleanup attempted after Route create failure');
});
