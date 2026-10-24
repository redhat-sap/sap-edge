// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { readFile } from 'node:fs/promises';
import { request } from 'node:https';
import { SetupError } from './inputs.mjs';

const accountDirectory = '/var/run/secrets/kubernetes.io/serviceaccount';
const resourcePaths = {
  pipelinerun: '/apis/tekton.dev/v1',
  taskrun: '/apis/tekton.dev/v1',
  secret: '/api/v1',
};
const validName = /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/;

// No kubeconfig or oc binary is needed in the pod. Only named GETs are supported.
export function inClusterReader(namespace) {
  if (!validName.test(namespace ?? '')) throw new SetupError('Invalid pipeline namespace.');
  return async (kind, name) => {
    if (!Object.hasOwn(resourcePaths, kind) || !validName.test(name ?? '')) {
      throw new SetupError('Invalid Kubernetes resource request.');
    }
    try {
      // Read the token on every request so projected-token rotation works.
      const [token, ca] = await Promise.all([
        readFile(`${accountDirectory}/token`, 'utf8'),
        readFile(`${accountDirectory}/ca.crt`),
      ]);
      const path = `${resourcePaths[kind]}/namespaces/${namespace}/${kind}s/${name}`;
      return await new Promise((resolve, reject) => {
        const req = request({
          hostname: 'kubernetes.default.svc', port: 443, path, ca,
          headers: { Authorization: `Bearer ${token.trim()}` },
        }, (response) => {
          if (response.statusCode !== 200) {
            response.resume();
            reject(new Error('Kubernetes request failed'));
            return;
          }
          let size = 0;
          const chunks = [];
          response.on('error', reject);
          response.on('data', (chunk) => {
            size += chunk.length;
            if (size > 8 * 1024 * 1024) req.destroy(new Error('Response too large'));
            else chunks.push(chunk);
          });
          response.on('end', () => {
            try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
            catch { reject(new Error('Invalid Kubernetes response')); }
          });
        });
        const deadline = setTimeout(() => req.destroy(new Error('Request timed out')), 35000);
        req.on('close', () => clearTimeout(deadline));
        req.on('error', reject);
        req.end();
      });
    } catch {
      // Never include HTTP bodies, headers or parser exceptions: these may contain secrets.
      throw new SetupError(`Cannot read ${kind}/${name}. Check the runner service account and network access.`);
    }
  };
}
