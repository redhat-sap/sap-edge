// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { SetupError } from './inputs.mjs';

// Short prefix: the router host <route>-<namespace>.<apps domain> needs a first
// label of at most 63 characters (cluster names have at most 30, which leaves
// 27 for the namespace), and the SA annotation name
// oauth-redirectreference.<route> must stay within 63 characters too.
export function routeName(clusterName) {
  return 'sapb-' + clusterName;
}

export async function openRoute(client, {
  name,
  podName,
  podUID,
  taskRunName,
  serviceAccount,
  port = 4180,
  timeoutMs = 120000,
  intervalMs = 2000,
}) {
  const ownerReferences = [{
    apiVersion: 'v1',
    kind: 'Pod',
    name: podName,
    uid: podUID,
  }];

  const serviceBody = {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name,
      ownerReferences,
    },
    spec: {
      selector: { 'tekton.dev/taskRun': taskRunName },
      ports: [{
        port,
        targetPort: port,
      }],
    },
  };

  const routeBody = {
    apiVersion: 'route.openshift.io/v1',
    kind: 'Route',
    metadata: {
      name,
      ownerReferences,
    },
    spec: {
      to: {
        kind: 'Service',
        name,
      },
      tls: {
        termination: 'edge',
        insecureEdgeTerminationPolicy: 'Redirect',
      },
    },
  };

  const annotationKey = `serviceaccounts.openshift.io/oauth-redirectreference.${name}`;
  const annotationValue = JSON.stringify({
    kind: 'OAuthRedirectReference',
    apiVersion: 'v1',
    reference: {
      kind: 'Route',
      name,
    },
  });

  const cleanup = () => cleanupResources(client, name, serviceAccount, annotationKey);

  try {
    // Create Service (with retry on conflict)
    await createWithRetry(client, 'service', serviceBody);

    // Create Route (with retry on conflict)
    await createWithRetry(client, 'route', routeBody);

    // Patch ServiceAccount annotation
    await client.patch('serviceaccount', serviceAccount, {
      metadata: {
        annotations: {
          [annotationKey]: annotationValue,
        },
      },
    });

    // Poll for Route admission
    const url = await pollForHost(client, name, timeoutMs, intervalMs);

    return { url, close: cleanup };
  } catch (error) {
    // Clean up any resources created before the error
    await cleanup();
    throw error;
  }
}

async function cleanupResources(client, name, serviceAccount, annotationKey) {
  try {
    await client.remove('route', name);
  } catch (error) {
    console.warn('Warning: failed to remove Route during cleanup');
  }

  try {
    await client.remove('service', name);
  } catch (error) {
    console.warn('Warning: failed to remove Service during cleanup');
  }

  try {
    await client.patch('serviceaccount', serviceAccount, {
      metadata: {
        annotations: {
          [annotationKey]: null,
        },
      },
    });
  } catch (error) {
    console.warn('Warning: failed to remove annotation during cleanup');
  }
}

async function createWithRetry(client, kind, body) {
  try {
    await client.create(kind, body);
  } catch (error) {
    if (error instanceof SetupError && error.code === 'exists') {
      // Remove stale resource and retry
      await client.remove(kind, body.metadata.name);
      await client.create(kind, body);
    } else {
      throw error;
    }
  }
}

// The URL only once the router has admitted the Route (a host alone can still
// be rejected, e.g. HostAlreadyClaimed or a host name that is too long).
async function pollForHost(client, name, timeoutMs, intervalMs) {
  const startTime = Date.now();

  while (Date.now() - startTime < timeoutMs) {
    const route = await client.get('route', name);
    const ingress = route.status?.ingress?.[0];
    const admitted = ingress?.conditions?.find((condition) => condition.type === 'Admitted');

    if (admitted?.status === 'False') {
      // The reason only (a CamelCase word), never the free-text message
      const reason = /^[A-Za-z0-9._-]{1,100}$/.test(admitted.reason ?? '') ? admitted.reason : 'unknown reason';
      throw new SetupError(`Route not admitted: ${reason}`);
    }
    if (admitted?.status === 'True' && ingress.host) {
      return `https://${ingress.host}/vnc.html?autoconnect=1&resize=remote&path=websockify`;
    }

    // Wait before next poll
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }

  throw new SetupError('Route was not admitted within the timeout period.');
}
