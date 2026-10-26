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

    // Check if aborted after async read
    if (signal?.aborted) {
      throw signal.reason || new Error('Wait aborted');
    }

    // Verify UID
    if (run.metadata?.uid !== pipelineRunUID) {
      throw new SetupError('PipelineRun UID does not match the expected run.');
    }

    // Check if the task was skipped
    const skipped = run.status?.skippedTasks?.some((task) => task.name === pipelineTaskName);
    if (skipped) {
      throw new SetupError(`Pipeline task ${pipelineTaskName} was skipped.`);
    }

    // Check if the run is stopping/cancelled: the Succeeded=Unknown reasons
    // Tekton sets then (PipelineRunStopping, then CancelledRunningFinally or
    // StoppedRunningFinally while finally tasks run); Cancelled for a finished
    // cancel (status False, also caught by the finished check below)
    const succeededCondition = run.status?.conditions?.find((cond) => cond.type === 'Succeeded');
    if (succeededCondition?.status === 'Unknown') {
      const stoppingReasons = ['PipelineRunStopping', 'CancelledRunningFinally', 'StoppedRunningFinally', 'Cancelled'];
      if (stoppingReasons.includes(succeededCondition.reason)) {
        throw new SetupError(`PipelineRun is stopping: ${succeededCondition.reason}`);
      }
    }

    // Find the TaskRun for the requested pipeline task
    const taskRef = run.status?.childReferences?.find((child) =>
      child.pipelineTaskName === pipelineTaskName && child.kind === 'TaskRun');

    // Check if the run finished without creating the task
    const runFinished = run.status?.conditions?.some((condition) =>
      condition.type === 'Succeeded' && (condition.status === 'True' || condition.status === 'False'));
    if (!taskRef && runFinished) {
      throw new SetupError(`PipelineRun finished without creating pipeline task: ${pipelineTaskName}`);
    }

    if (taskRef) {
      // Read the TaskRun to check its status
      const task = await read('taskrun', taskRef.name);

      // Check if aborted after async read
      if (signal?.aborted) {
        throw signal.reason || new Error('Wait aborted');
      }

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
    try {
      if (signal) {
        await delay(intervalMs, undefined, { signal });
      } else {
        await delay(intervalMs);
      }
    } catch (e) {
      if (signal?.aborted) {
        throw signal.reason || new Error('Wait aborted');
      }
      throw e;
    }
  }
}
