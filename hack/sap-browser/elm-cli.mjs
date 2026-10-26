// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { spawn } from 'node:child_process';
import { execFile } from 'node:child_process';
import { chmod, readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { SetupError } from './inputs.mjs';

const execute = promisify(execFile);

export async function fetchElmCli(s3, dir) {
  const objects = await s3.list('tools/elm/');
  // Filter out directory markers (keys ending with /)
  const files = objects.filter((obj) => !obj.key.endsWith('/'));

  if (files.length === 0) {
    throw new SetupError('No elm CLI in tools/elm/ of the bucket. Download the Linux x86_64 ELM CLI from the SAP Software Download Center and upload it there.');
  }

  // Sort by lastModified descending, pick the newest
  files.sort((a, b) => new Date(b.lastModified) - new Date(a.lastModified));
  const newest = files[0];
  const key = newest.key;
  const filename = key.split('/').pop();

  // Download the file
  const downloadPath = join(dir, filename);
  await s3.get(key, downloadPath);
  console.log(`Downloaded ${key}`);

  let elmPath;

  // Handle different file types
  if (filename.endsWith('.sar') || filename.endsWith('.SAR')) {
    throw new SetupError('SAR archives are not supported: extract the elm binary with SAPCAR and upload it, or a zip/tar.gz, to tools/elm/.');
  } else if (filename.endsWith('.zip')) {
    // Extract zip
    await execute('unzip', ['-o', downloadPath, '-d', dir]);
    elmPath = await findElmBinary(dir);
  } else if (filename.endsWith('.tar.gz') || filename.endsWith('.tgz')) {
    // Extract tar.gz
    await execute('tar', ['xzf', downloadPath, '-C', dir]);
    elmPath = await findElmBinary(dir);
  } else {
    // Assume it's the binary itself
    elmPath = downloadPath;
  }

  // Make executable
  await chmod(elmPath, 0o700);
  return elmPath;
}

async function findElmBinary(dir, depth = 0) {
  if (depth > 3) {
    throw new SetupError('Could not find elm binary in the extracted archive (searched up to depth 3).');
  }

  const entries = await readdir(dir, { withFileTypes: true });

  // First check current directory for a file named 'elm'
  for (const entry of entries) {
    if (entry.isFile() && entry.name === 'elm') {
      return join(dir, entry.name);
    }
  }

  // Then search subdirectories
  for (const entry of entries) {
    if (entry.isDirectory()) {
      try {
        return await findElmBinary(join(dir, entry.name), depth + 1);
      } catch (error) {
        // Continue searching in other directories
        if (!(error instanceof SetupError && error.message.includes('Could not find'))) {
          throw error;
        }
      }
    }
  }

  throw new SetupError('Could not find elm binary in the extracted archive (searched up to depth 3).');
}

export async function runElmInit({
  elmPath,
  contextFile,
  password,
  cwd,
  timeoutMs = 600000,
  spawnImpl = spawn,
  platform = process.platform,
  log = console.log,
}) {
  const env = {
    PATH: process.env.PATH,
    HOME: cwd,
    TERM: 'dumb',
  };

  // On macOS, BSD script doesn't properly forward stdin, so use expect instead
  // On Linux, use script with -c flag
  let command, args;
  if (platform === 'darwin') {
    // macOS: use expect for PTY automation
    command = 'expect';
    args = []; // expect will read from stdin (the script we send)
  } else {
    // Linux: script -q -e -c '<elm> init -c <cfg>' /dev/null
    const quotedElm = `'${elmPath.replace(/'/g, "'\\''")}'`;
    const quotedCfg = `'${contextFile.replace(/'/g, "'\\''")}'`;
    command = 'script';
    args = ['-q', '-e', '-c', `${quotedElm} init -c ${quotedCfg}`, '/dev/null'];
  }

  if (platform === 'darwin') {
    // Use expect on macOS
    return new Promise((resolve, reject) => {
      // Generate the expect script
      const escapedElm = elmPath.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$');
      const escapedCfg = contextFile.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$');
      const escapedPwd = password.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$').replace(/\[/g, '\\[').replace(/\]/g, '\\]');
      const expectScript = `
log_user 1
set timeout ${Math.ceil(timeoutMs / 1000)}
spawn "${escapedElm}" init -c "${escapedCfg}"
expect -re "(?i)password"
send "${escapedPwd}\\r"
expect eof
lassign [wait] pid spawnid os_error_flag value
exit $value
`;

      const child = spawnImpl(command, args, { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
      let lineBuffer = '';
      let timeoutHandle;

      const cleanup = () => {
        if (timeoutHandle) clearTimeout(timeoutHandle);
      };

      const fail = (error) => {
        cleanup();
        child.kill();
        reject(error);
      };

      timeoutHandle = setTimeout(() => {
        fail(new SetupError('elm init timed out'));
      }, timeoutMs + 1000); // Add 1s buffer for expect's own timeout

      // Send the expect script to stdin
      child.stdin.write(expectScript);
      child.stdin.end();

      // Capture and log output with password masking
      const onData = (data) => {
        const text = data.toString();
        lineBuffer += text;

        // Process complete lines
        const lines = lineBuffer.split('\n');
        lineBuffer = lines.pop() || '';

        for (const line of lines) {
          const masked = line.split(password).join('***');
          log(masked);
        }
      };

      if (child.stdout) {
        child.stdout.on('data', onData);
      }
      if (child.stderr) {
        child.stderr.on('data', onData);
      }

      child.on('error', (error) => {
        fail(new SetupError(`Failed to run elm init: ${error.message}`));
      });

      child.on('exit', (code, signal) => {
        cleanup();

        // Log any remaining output
        if (lineBuffer) {
          const masked = lineBuffer.split(password).join('***');
          log(masked);
        }

        if (code === 0) {
          resolve();
        } else if (signal) {
          reject(new SetupError(`elm init was killed with signal ${signal}`));
        } else {
          reject(new SetupError(`elm init failed (exit ${code})`));
        }
      });
    });
  } else {
    // Use script on Linux
    return new Promise((resolve, reject) => {
      const child = spawnImpl(command, args, { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
      let fullOutput = '';
      let lineBuffer = '';
      let passwordSent = false;
      let timeoutHandle;

      const cleanup = () => {
        if (timeoutHandle) clearTimeout(timeoutHandle);
      };

      const fail = (error) => {
        cleanup();
        child.kill();
        reject(error);
      };

      timeoutHandle = setTimeout(() => {
        fail(new SetupError('elm init timed out'));
      }, timeoutMs);

      const onData = (data) => {
        const text = data.toString();
        fullOutput += text;
        lineBuffer += text;

        // Send password when we see the password prompt
        if (!passwordSent && fullOutput.toLowerCase().includes('password')) {
          passwordSent = true;
          child.stdin.write(password + '\n');
        }

        // Process complete lines
        const lines = lineBuffer.split('\n');
        lineBuffer = lines.pop() || '';

        for (const line of lines) {
          const masked = line.split(password).join('***');
          log(masked);
        }
      };

      if (child.stdout) {
        child.stdout.on('data', onData);
      }
      if (child.stderr) {
        child.stderr.on('data', onData);
      }

      child.on('error', (error) => {
        fail(new SetupError(`Failed to run elm init: ${error.message}`));
      });

      child.on('exit', (code, signal) => {
        cleanup();

        // Log any remaining output
        if (lineBuffer) {
          const masked = lineBuffer.split(password).join('***');
          log(masked);
        }

        if (code === 0) {
          resolve();
        } else if (signal) {
          reject(new SetupError(`elm init was killed with signal ${signal}`));
        } else {
          reject(new SetupError(`elm init failed (exit ${code})`));
        }
      });
    });
  }
}
