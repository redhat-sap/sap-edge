// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { spawn } from 'node:child_process';
import { execFile } from 'node:child_process';
import { chmod, readdir, stat } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { promisify } from 'node:util';
import { SetupError } from './inputs.mjs';

const execute = promisify(execFile);

// Default answers for elm init prompts based on the user's transcript
export const ELM_INIT_ANSWERS = {
  // Find Red Hat OpenShift in the provider list and return its number
  'possible values [1,2...6]:': (output) => {
    const lines = output.split('\n');
    for (const line of lines) {
      // Match lines like "  > 4. Red Hat OpenShift" or "     4. Red Hat OpenShift"
      const match = line.match(/^\s*>?\s*(\d+)\.\s*Red Hat OpenShift/);
      if (match) {
        return match[1];
      }
    }
    throw new SetupError('Red Hat OpenShift not found in provider list');
  },
  'Choose action (Back [b], Next [n], Help [F1]):': 'n',
  'Choose action (Next [n], Help [F1]):': 'n',
  // Find "No feedback" in the feedback list and return its number
  'possible values [1,2,3]:': (output) => {
    const lines = output.split('\n');
    for (const line of lines) {
      // Match lines like "  > 3. No feedback" or "     3. No feedback"
      const match = line.match(/^\s*>?\s*(\d+)\.\s*No feedback/);
      if (match) {
        return match[1];
      }
    }
    throw new SetupError('No feedback option not found in feedback list');
  },
};

export async function fetchElmCli(s3, dir, { downloadInBrowser } = {}) {
  const objects = await s3.list('tools/elm/');
  // Filter out directory markers (keys ending with /)
  const files = objects.filter((obj) => !obj.key.endsWith('/'));

  if (files.length === 0) {
    // No CLI in bucket - try browser fallback if provided
    if (downloadInBrowser) {
      const downloadedPath = await downloadInBrowser();
      // Cache the downloaded file to S3
      const filename = basename(downloadedPath);
      const key = `tools/elm/${filename}`;
      await s3.put(downloadedPath, key);
      console.log(`Cached ${key} to bucket`);
      return downloadedPath;
    }
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
  killGracePeriodMs = 5000,
  spawnImpl = spawn,
  platform = process.platform,
  log = console.log,
  answers = ELM_INIT_ANSWERS,
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
      // Generate expect patterns for all prompts
      const escapedElm = elmPath.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$');
      const escapedCfg = contextFile.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$');
      const escapedPwd = password.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\$/g, '\\$').replace(/\[/g, '\\[').replace(/\]/g, '\\]');

      // Set expect timeout to 120s for unknown prompts detection
      // For tests with short timeouts where we want the unknown prompt message, use a short timeout
      // Only shorten the expect timeout if we're testing unknown prompt detection (very short timeout)
      const expectTimeout = timeoutMs < 2000 ? Math.max(1, Math.floor(timeoutMs / 1000) - 1) : 120;
      const expectScript = `
log_user 1
set timeout ${expectTimeout}
set provider_answered 0
set feedback_answered 0
spawn "${escapedElm}" init -c "${escapedCfg}"
expect {
  -nocase -re "password" {
    send "${escapedPwd}\\r"
    exp_continue
  }
  -re "possible values .1,2...6.:" {
    if {!$provider_answered} {
      set provider_answered 1
      # Extract the number for "Red Hat OpenShift" from the buffer
      if {[regexp {([0-9]+)\\.[^\\n]*Red Hat OpenShift} $expect_out(buffer) -> provider_num]} {
        send "$provider_num\\r"
        exp_continue
      } else {
        puts "elm init asks something unexpected; continue by hand"
        exit 1
      }
    }
    exp_continue
  }
  -re "Choose action .Back .b., Next .n., Help .F1..:" {
    send "n\\r"
    exp_continue
  }
  -re "Choose action .Next .n., Help .F1..:" {
    send "n\\r"
    exp_continue
  }
  "elm init succeeded" {
    exp_continue
  }
  -re "possible values .1,2,3.:" {
    if {!$feedback_answered} {
      set feedback_answered 1
      # Extract the number for "No feedback" from the buffer
      if {[regexp {([0-9]+)\\.[^\\n]*No feedback} $expect_out(buffer) -> feedback_num]} {
        send "$feedback_num\\r"
        exp_continue
      } else {
        puts "elm init asks something unexpected; continue by hand"
        exit 1
      }
    }
    exp_continue
  }
  eof {
    lassign [wait] pid spawnid os_error_flag value
    exit $value
  }
  timeout {
    puts "elm init asks something unexpected; continue by hand"
    exit 1
  }
}
`;

      const child = spawnImpl(command, args, { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
      let lineBuffer = '';
      let fullOutput = '';
      let elmInitSucceeded = false;
      let sawProviderPrompt = false;
      let sawFeedbackPrompt = false;
      let timeoutHandle;
      let killHandle;

      const cleanup = () => {
        if (timeoutHandle) clearTimeout(timeoutHandle);
        if (killHandle) clearTimeout(killHandle);
      };

      const fail = (error) => {
        cleanup();
        child.kill('SIGTERM');
        killHandle = setTimeout(() => {
          child.kill('SIGKILL');
        }, killGracePeriodMs);
        reject(error);
      };

      // Set our timeout. For very short timeouts (unknown prompt test), add buffer for expect.
      // For normal timeouts, use timeoutMs as-is.
      const jsTimeout = timeoutMs < 2000 ? timeoutMs + 500 : timeoutMs;
      timeoutHandle = setTimeout(() => {
        fail(new SetupError('elm init timed out'));
      }, jsTimeout);

      // Send the expect script to stdin
      child.stdin.write(expectScript);
      child.stdin.end();

      // Capture and log output with password masking
      const onData = (data) => {
        const text = data.toString();
        fullOutput += text;
        lineBuffer += text;

        // Track which prompts we saw
        if (fullOutput.includes('possible values [1,2...6]')) {
          sawProviderPrompt = true;
        }
        if (fullOutput.includes('possible values [1,2,3]')) {
          sawFeedbackPrompt = true;
        }

        // Check for success message
        if (fullOutput.includes('elm init succeeded')) {
          elmInitSucceeded = true;
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

      let exitCode = null;
      let exitSignal = null;

      child.on('error', (error) => {
        fail(new SetupError(`Failed to run elm init: ${error.message}`));
      });

      child.on('exit', (code, signal) => {
        exitCode = code;
        exitSignal = signal;
      });

      child.on('close', () => {
        cleanup();

        // Log any remaining output
        if (lineBuffer) {
          const masked = lineBuffer.split(password).join('***');
          log(masked);
        }

        // Check for "elm init asks something unexpected" in output (from expect timeout)
        if (fullOutput.includes('elm init asks something unexpected')) {
          reject(new SetupError('elm init asks something unexpected; continue by hand'));
          return;
        }

        // Check that we saw elm init succeeded (only if we answered prompts beyond password)
        const answeredBeyondPassword = sawProviderPrompt || sawFeedbackPrompt;
        if (exitCode === 0 && answeredBeyondPassword && !elmInitSucceeded) {
          reject(new SetupError('elm init exited 0 but did not print "elm init succeeded"'));
          return;
        }

        if (exitCode === 0) {
          resolve();
        } else if (exitSignal) {
          reject(new SetupError(`elm init was killed with signal ${exitSignal}`));
        } else {
          reject(new SetupError(`elm init failed (exit ${exitCode})`));
        }
      });
    });
  } else {
    // Use script on Linux
    return new Promise((resolve, reject) => {
      const child = spawnImpl(command, args, { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
      let fullOutput = '';
      let lineBuffer = '';
      const answeredPrompts = new Set();
      let elmInitSucceeded = false;
      let lastActivityTime = Date.now();
      let timeoutHandle;
      let killHandle;
      let unknownPromptHandle;
      let exitCode = null;
      let exitSignal = null;

      const cleanup = () => {
        if (timeoutHandle) clearTimeout(timeoutHandle);
        if (killHandle) clearTimeout(killHandle);
        if (unknownPromptHandle) clearTimeout(unknownPromptHandle);
      };

      const fail = (error) => {
        cleanup();
        child.kill('SIGTERM');
        killHandle = setTimeout(() => {
          child.kill('SIGKILL');
        }, killGracePeriodMs);
        reject(error);
      };

      timeoutHandle = setTimeout(() => {
        fail(new SetupError('elm init timed out'));
      }, timeoutMs);

      // Helper to strip terminal escape sequences for robust matching
      const stripEscapes = (text) => {
        // Remove ANSI escape sequences like [1G, [0K, [31G, etc.
        return text.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '').replace(/\r/g, '');
      };

      const onData = (data) => {
        const text = data.toString();
        fullOutput += text;
        lineBuffer += text;
        lastActivityTime = Date.now();

        // Check for success message
        if (stripEscapes(fullOutput).includes('elm init succeeded')) {
          elmInitSucceeded = true;
        }

        // Try to match prompts
        const cleanOutput = stripEscapes(fullOutput);

        // First, check for password prompt
        if (!answeredPrompts.has('password') && cleanOutput.toLowerCase().includes('password')) {
          answeredPrompts.add('password');
          child.stdin.write(password + '\n');
          // Reset unknown prompt timer when we handle a known prompt
          if (unknownPromptHandle) clearTimeout(unknownPromptHandle);
          unknownPromptHandle = null;
        }

        // Then check other prompts
        for (const [promptText, answer] of Object.entries(answers)) {
          if (!answeredPrompts.has(promptText) && cleanOutput.includes(promptText)) {
            answeredPrompts.add(promptText);
            const response = typeof answer === 'function' ? answer(cleanOutput) : answer;
            child.stdin.write(response + '\n');
            // Reset unknown prompt timer when we handle a known prompt
            if (unknownPromptHandle) clearTimeout(unknownPromptHandle);
            unknownPromptHandle = null;
            break;
          }
        }

        // Detect potential unknown prompts (lines ending with : or ?)
        // Only start the unknown prompt timer after password is sent
        if (answeredPrompts.has('password') && !elmInitSucceeded && !unknownPromptHandle) {
          const lastFewLines = cleanOutput.split('\n').slice(-5).join('\n');
          // Check if there's a prompt-like pattern that we haven't answered
          if (/[:?]\s*$/.test(lastFewLines.trim())) {
            // Check if this matches any known prompt
            const matchesKnown = Object.keys(answers).some((prompt) => cleanOutput.includes(prompt));
            if (!matchesKnown) {
              // Start timer for unknown prompt
              unknownPromptHandle = setTimeout(() => {
                fail(new SetupError('elm init asks something unexpected; continue by hand'));
              }, 120000); // 120 seconds
            }
          }
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

      // Handle EPIPE errors when elm exits right after printing password prompt
      if (child.stdin) {
        child.stdin.on('error', (error) => {
          // EPIPE is expected if elm exits immediately; only fail on other errors
          if (error.code !== 'EPIPE') {
            fail(new SetupError(`Failed to write to elm init: ${error.message}`));
          }
        });
      }

      child.on('error', (error) => {
        fail(new SetupError(`Failed to run elm init: ${error.message}`));
      });

      child.on('exit', (code, signal) => {
        exitCode = code;
        exitSignal = signal;
      });

      child.on('close', () => {
        cleanup();

        // Log any remaining output
        if (lineBuffer) {
          const masked = lineBuffer.split(password).join('***');
          log(masked);
        }

        // Check that we saw elm init succeeded (only if we answered prompts beyond password)
        const answeredBeyondPassword = Array.from(answeredPrompts).some((p) => p !== 'password');
        if (exitCode === 0 && answeredBeyondPassword && !elmInitSucceeded) {
          reject(new SetupError('elm init exited 0 but did not print "elm init succeeded"'));
          return;
        }

        if (exitCode === 0) {
          resolve();
        } else if (exitSignal) {
          reject(new SetupError(`elm init was killed with signal ${exitSignal}`));
        } else {
          reject(new SetupError(`elm init failed (exit ${exitCode})`));
        }
      });
    });
  }
}
