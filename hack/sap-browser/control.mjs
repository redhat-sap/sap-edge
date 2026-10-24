// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { finishSession } from './session.mjs';
import { SetupError } from './inputs.mjs';

const directory = process.env.SAP_BROWSER_SESSION_DIR || '/tmp/sap-browser-session';
try {
  if (process.argv[2] === 'status') {
    console.log(await readFile(join(directory, 'status.json'), 'utf8'));
  } else if (process.argv[2] === 'finish') {
    await finishSession(directory);
    console.log('Closing the browser session. The existing approval gate still requires manual approval.');
  } else {
    throw new SetupError('Usage: node /opt/sap-browser/control.mjs status|finish');
  }
} catch (error) {
  console.error(error instanceof SetupError ? error.message : 'Session control unavailable. Check the task logs.');
  process.exitCode = 1;
}
