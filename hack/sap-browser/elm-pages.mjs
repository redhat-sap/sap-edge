// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { randomBytes } from 'node:crypto';
import { SetupError } from './inputs.mjs';

function notMapped(method) {
  throw new SetupError(`ELM screen step not mapped yet: ${method}. Record it with sapBrowserMode inspect.`);
}

export const elmPages = {
  async edgeNodeState(page, clusterName) {
    notMapped('edgeNodeState');
  },

  async edgeNodeId(page, clusterName) {
    notMapped('edgeNodeId');
  },

  async addEdgeNode(page, { clusterName, registry }) {
    notMapped('addEdgeNode');
  },

  async downloadElmZip(page, { clusterName, dir }) {
    notMapped('downloadElmZip');
  },

  async setUpCloudConnector(page, { clusterName, kubeconfigFile, password, dir }) {
    notMapped('setUpCloudConnector');
  },

  async deployEic(page, { clusterName, inputs, files }) {
    notMapped('deployEic');
  },

  async downloadEicZip(page, { clusterName, dir }) {
    notMapped('downloadEicZip');
  },

  async finishEicDeployment(page, { clusterName }) {
    notMapped('finishEicDeployment');
  },

  async deleteEdgeNode(page, { clusterName }) {
    notMapped('deleteEdgeNode');
  },
};

export function contextPassword() {
  return randomBytes(24).toString('base64url');
}
