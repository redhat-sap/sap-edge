// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { waitForPipelineTask } from './milestones.mjs';

const successfulTask = {
  metadata: { ownerReferences: [{ uid: 'run-uid' }] },
  status: { conditions: [{ type: 'Succeeded', status: 'True' }] },
};

const failedTask = {
  metadata: { ownerReferences: [{ uid: 'run-uid' }] },
  status: { conditions: [{ type: 'Succeeded', status: 'False' }] },
};

const runWithTask = (taskName = 'generate-sa-based-kubeconfig') => ({
  metadata: { uid: 'run-uid' },
  status: {
    childReferences: [
      { name: 'task-1', kind: 'TaskRun', pipelineTaskName: taskName },
    ],
  },
});

const runWithoutTask = {
  metadata: { uid: 'run-uid' },
  status: {
    conditions: [{ type: 'Succeeded', status: 'True' }],
    childReferences: [],
  },
};

test('resolves_after_success', async () => {
  let calls = 0;
  const reader = async (kind, name) => {
    calls++;
    if (kind === 'pipelinerun' && name === 'run-1') return runWithTask();
    if (kind === 'taskrun' && name === 'task-1') {
      // Simulate task completing after a few polls
      if (calls < 3) {
        return {
          metadata: { ownerReferences: [{ uid: 'run-uid' }] },
          status: { conditions: [{ type: 'Succeeded', status: 'Unknown' }] },
        };
      }
      return successfulTask;
    }
    throw new Error(`Unexpected read: ${kind}/${name}`);
  };

  await waitForPipelineTask(reader, {
    pipelineRun: 'run-1',
    pipelineRunUID: 'run-uid',
    pipelineTaskName: 'generate-sa-based-kubeconfig',
    intervalMs: 10,
  });

  assert.ok(calls >= 3);
});

test('rejects_on_failure', async () => {
  const reader = async (kind, name) => {
    if (kind === 'pipelinerun' && name === 'run-1') return runWithTask();
    if (kind === 'taskrun' && name === 'task-1') return failedTask;
    throw new Error(`Unexpected read: ${kind}/${name}`);
  };

  await assert.rejects(
    waitForPipelineTask(reader, {
      pipelineRun: 'run-1',
      pipelineRunUID: 'run-uid',
      pipelineTaskName: 'generate-sa-based-kubeconfig',
      intervalMs: 10,
    }),
    /failed|False/i
  );
});

test('rejects_when_run_finished_without_task', async () => {
  const reader = async (kind, name) => {
    if (kind === 'pipelinerun' && name === 'run-1') return runWithoutTask;
    throw new Error(`Unexpected read: ${kind}/${name}`);
  };

  await assert.rejects(
    waitForPipelineTask(reader, {
      pipelineRun: 'run-1',
      pipelineRunUID: 'run-uid',
      pipelineTaskName: 'generate-sa-based-kubeconfig',
      intervalMs: 10,
    }),
    /finished without.*generate-sa-based-kubeconfig/i
  );
});

test('honors_abort', async () => {
  const abort = new AbortController();
  const reason = new Error('Test abort reason');
  const reader = async (kind, name) => {
    if (kind === 'pipelinerun' && name === 'run-1') return runWithTask();
    if (kind === 'taskrun' && name === 'task-1') {
      return {
        metadata: { ownerReferences: [{ uid: 'run-uid' }] },
        status: { conditions: [{ type: 'Succeeded', status: 'Unknown' }] },
      };
    }
    throw new Error(`Unexpected read: ${kind}/${name}`);
  };

  const waitPromise = waitForPipelineTask(reader, {
    pipelineRun: 'run-1',
    pipelineRunUID: 'run-uid',
    pipelineTaskName: 'generate-sa-based-kubeconfig',
    signal: abort.signal,
    intervalMs: 100,
  });

  // Abort after a short delay (during the wait)
  await delay(20);
  abort.abort(reason);

  await assert.rejects(waitPromise, (e) => e === reason);
});

test('rejects_when_task_skipped', async () => {
  const reader = async (kind, name) => {
    if (kind === 'pipelinerun' && name === 'run-1') {
      return {
        metadata: { uid: 'run-uid' },
        status: {
          skippedTasks: [{ name: 'generate-sa-based-kubeconfig' }],
          childReferences: [],
        },
      };
    }
    throw new Error(`Unexpected read: ${kind}/${name}`);
  };

  await assert.rejects(
    waitForPipelineTask(reader, {
      pipelineRun: 'run-1',
      pipelineRunUID: 'run-uid',
      pipelineTaskName: 'generate-sa-based-kubeconfig',
      intervalMs: 10,
    }),
    /skipped/i
  );
});

test('rejects_when_run_stopping', async () => {
  for (const reason of ['PipelineRunStopping', 'Stopping', 'Cancelled', 'CancelledRunFinally', 'StoppedRunFinally']) {
    const reader = async (kind, name) => {
      if (kind === 'pipelinerun' && name === 'run-1') {
        return {
          metadata: { uid: 'run-uid' },
          status: {
            conditions: [{ type: 'Succeeded', status: 'Unknown', reason }],
            childReferences: [],
          },
        };
      }
      throw new Error(`Unexpected read: ${kind}/${name}`);
    };

    await assert.rejects(
      waitForPipelineTask(reader, {
        pipelineRun: 'run-1',
        pipelineRunUID: 'run-uid',
        pipelineTaskName: 'generate-sa-based-kubeconfig',
        intervalMs: 10,
      }),
      /stopping/i,
      `Should reject for reason: ${reason}`
    );
  }
});
