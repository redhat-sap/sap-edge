// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { setTimeout as delay } from 'node:timers/promises';
import { SetupError } from './inputs.mjs';

export async function waitForPipelineTask(read, {
  pipelineRun,
  pipelineRunUID,
  pipelineTaskName,
  signal,
  intervalMs = 15000,
  onWait,
} = {}) {
  while (true) {
    // Check if aborted
    if (signal?.aborted) {
      throw signal.reason || new Error('Wait aborted');
    }

    // Read the PipelineRun
    const run = await read('pipelinerun', pipelineRun);

    // Verify UID
    if (run.metadata?.uid !== pipelineRunUID) {
      throw new SetupError('PipelineRun UID does not match the expected run.');
    }

    // Find the TaskRun for the requested pipeline task
    const taskRef = run.status?.childReferences?.find((child) =>
      child.pipelineTaskName === pipelineTaskName && child.kind === 'TaskRun');

    // Check if the run finished but the task was never created
    const runFinished = run.status?.conditions?.some((condition) =>
      condition.type === 'Succeeded' && (condition.status === 'True' || condition.status === 'False'));

    if (!taskRef && runFinished) {
      throw new SetupError(`PipelineRun finished without creating pipeline task: ${pipelineTaskName}`);
    }

    if (taskRef) {
      // Read the TaskRun to check its status
      const task = await read('taskrun', taskRef.name);

      // Verify ownership
      const ownedByRun = task.metadata?.ownerReferences?.some((owner) => owner.uid === pipelineRunUID);
      if (!ownedByRun) {
        throw new SetupError('TaskRun does not belong to the expected PipelineRun.');
      }

      // Check status
      const condition = task.status?.conditions?.find((cond) => cond.type === 'Succeeded');
      if (condition?.status === 'True') {
        // Success!
        return;
      }
      if (condition?.status === 'False') {
        throw new SetupError(`Pipeline task ${pipelineTaskName} failed.`);
      }
    }

    // Task not ready yet, wait before polling again
    if (onWait) {
      await onWait();
    }

    // Wait for the next poll, but respect abort signal
    if (signal) {
      await delay(intervalMs, undefined, { signal });
    } else {
      await delay(intervalMs);
    }
  }
}
