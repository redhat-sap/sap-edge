// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { Writable } from 'node:stream';
import { promisify } from 'node:util';
import { fetchElmCli, runElmInit } from './elm-cli.mjs';

const execute = promisify(execFile);

test('fetch_picks_newest', async () => {
  const mockS3 = {
    list: async (prefix) => {
      assert.equal(prefix, 'tools/elm/');
      return [
        { key: 'tools/elm/old-elm', lastModified: '2026-10-20T10:00:00Z', size: 1024 },
        { key: 'tools/elm/newer-elm', lastModified: '2026-10-26T10:00:00Z', size: 2048 },
        { key: 'tools/elm/middle-elm', lastModified: '2026-10-25T10:00:00Z', size: 1536 },
        { key: 'tools/elm/', lastModified: '2026-10-27T10:00:00Z', size: 0 }, // directory, should be ignored
      ];
    },
    get: async (key, destFile) => {
      assert.equal(key, 'tools/elm/newer-elm');
      await writeFile(destFile, '#!/bin/sh\necho "fake elm"\n');
    },
  };
  const folder = await mkdtemp(join(tmpdir(), 'elm-test-'));
  try {
    const elmPath = await fetchElmCli(mockS3, folder);
    assert.equal(elmPath, join(folder, 'newer-elm'));
    // Verify it's executable
    const { stdout } = await execute(elmPath, []);
    assert.equal(stdout.trim(), 'fake elm');
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('fetch_extracts_tar_gz', async () => {
  // Create a real tar.gz archive with an elm binary in a subdirectory
  const buildFolder = await mkdtemp(join(tmpdir(), 'elm-build-'));
  const extractFolder = await mkdtemp(join(tmpdir(), 'elm-extract-'));
  try {
    const nestedDir = join(buildFolder, 'elm-cli-v1.2.3', 'bin');
    await mkdir(nestedDir, { recursive: true });
    const elmScript = join(nestedDir, 'elm');
    await writeFile(elmScript, '#!/bin/sh\necho "elm from tar"\n');
    await chmod(elmScript, 0o755);
    const tarFile = join(buildFolder, 'elm-cli.tar.gz');
    await execute('tar', ['-czf', tarFile, '-C', buildFolder, 'elm-cli-v1.2.3']);

    const mockS3 = {
      list: async (prefix) => [
        { key: 'tools/elm/elm-cli.tar.gz', lastModified: '2026-10-26T10:00:00Z', size: 1024 },
      ],
      get: async (key, destFile) => {
        await execute('cp', [tarFile, destFile]);
      },
    };

    const elmPath = await fetchElmCli(mockS3, extractFolder);
    assert.ok(elmPath.endsWith('/elm'));
    const { stdout } = await execute(elmPath, []);
    assert.equal(stdout.trim(), 'elm from tar');
  } finally {
    await rm(buildFolder, { recursive: true, force: true });
    await rm(extractFolder, { recursive: true, force: true });
  }
});

test('fetch_rejects_sar', async () => {
  const mockS3 = {
    list: async (prefix) => [
      { key: 'tools/elm/elm-cli.SAR', lastModified: '2026-10-26T10:00:00Z', size: 1024 },
    ],
    get: async (key, destFile) => {
      await writeFile(destFile, 'fake sar content');
    },
  };
  const folder = await mkdtemp(join(tmpdir(), 'elm-test-'));
  try {
    await assert.rejects(
      fetchElmCli(mockS3, folder),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('SAR'));
        assert.ok(err.message.includes('SAPCAR'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('fetch_reports_missing_cli', async () => {
  const mockS3 = {
    list: async (prefix) => [],
  };
  const folder = await mkdtemp(join(tmpdir(), 'elm-test-'));
  try {
    await assert.rejects(
      fetchElmCli(mockS3, folder),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('No elm CLI'));
        assert.ok(err.message.includes('tools/elm/'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_answers_prompt', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'test-password-123';
    // Create a fake elm script that prompts for password
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Context Password: ' pw
echo
if [ "$pw" = "${password}" ]; then
  echo "Context initialized successfully"
  exit 0
else
  echo "Wrong password"
  exit 3
fi
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await runElmInit({
      elmPath,
      contextFile,
      password,
      cwd: folder,
      timeoutMs: 10000,
      platform: process.platform,
    });
    // If we get here, the test passed
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_wrong_password_fails', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'correct-password';
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Context Password: ' pw
echo
if [ "$pw" = "${password}" ]; then
  echo "Context initialized successfully"
  exit 0
else
  echo "Wrong password"
  exit 3
fi
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await assert.rejects(
      runElmInit({
        elmPath,
        contextFile,
        password: 'wrong-password',
        cwd: folder,
        timeoutMs: 10000,
        platform: process.platform,
      }),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('elm init failed'));
        assert.ok(err.message.includes('exit 3'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_masks_password', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'secret-password-xyz';
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Context Password: ' pw
echo
echo "You entered: $pw"
if [ "$pw" = "${password}" ]; then
  echo "Password was ${password}"
  exit 0
else
  exit 3
fi
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    const logLines = [];
    const log = (line) => logLines.push(line);

    await runElmInit({
      elmPath,
      contextFile,
      password,
      cwd: folder,
      timeoutMs: 10000,
      platform: process.platform,
      log,
    });

    const fullLog = logLines.join('\n');
    assert.ok(!fullLog.includes(password), `Password should not appear in logs: ${fullLog}`);
    assert.ok(fullLog.includes('***'), 'Password should be masked with ***');
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_env_has_no_aws_keys', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    process.env.AWS_ACCESS_KEY_ID = 'test-should-not-leak';
    process.env.AWS_SECRET_ACCESS_KEY = 'secret-should-not-leak';

    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'test-password';
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Context Password: ' pw
echo
env
exit 0
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    const logLines = [];
    const log = (line) => logLines.push(line);

    await runElmInit({
      elmPath,
      contextFile,
      password,
      cwd: folder,
      timeoutMs: 10000,
      platform: process.platform,
      log,
    });

    const fullLog = logLines.join('\n');
    assert.ok(!fullLog.includes('AWS_ACCESS_KEY_ID'), 'AWS credentials should not be in env');
    assert.ok(!fullLog.includes('AWS_SECRET_ACCESS_KEY'), 'AWS credentials should not be in env');
    assert.ok(fullLog.includes('HOME='), 'HOME should be in env');
    assert.ok(fullLog.includes('PATH='), 'PATH should be in env');
    assert.ok(fullLog.includes('TERM=dumb'), 'TERM should be dumb');

    delete process.env.AWS_ACCESS_KEY_ID;
    delete process.env.AWS_SECRET_ACCESS_KEY;
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_fails_when_elm_exits_before_prompt', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    await writeFile(elmPath, `#!/bin/bash
echo "Error: boom"
exit 2
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await assert.rejects(
      runElmInit({
        elmPath,
        contextFile,
        password: 'test',
        cwd: folder,
        platform: process.platform,
      }),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('elm init failed'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

// Pid a fake elm wrote to file, polled until it is there (at most withinMs)
async function waitForPid(file, withinMs) {
  const deadline = Date.now() + withinMs;
  while (Date.now() < deadline) {
    try {
      const pid = Number.parseInt((await readFile(file, 'utf8')).trim(), 10);
      if (Number.isInteger(pid) && pid > 0) return pid;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return assert.fail(`fake elm did not write ${file} within ${withinMs} ms`);
}

test('init_times_out', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const pidFile = join(folder, 'elm.pid');
    await writeFile(elmPath, `#!/bin/bash
echo $$ > "${pidFile}"
read -rs -p 'Context Password: ' pw
echo
sleep 10
exit 0
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    // Enough headroom for expect to start and spawn the fake elm on a loaded
    // machine: with 500 ms the timeout sometimes fired before elm existed, so
    // there was no pid file (and no process) to check.
    const timeoutMs = 4000;
    const started = Date.now();
    const rejection = assert.rejects(
      runElmInit({
        elmPath,
        contextFile,
        password: 'test',
        cwd: folder,
        timeoutMs,
        killGracePeriodMs: 500,
        platform: process.platform,
      }),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('elm init timed out'));
        return true;
      }
    );
    rejection.catch(() => {}); // awaited below; no unhandled rejection if an assertion fails first

    // The fake elm runs before the timeout fires...
    const pid = await waitForPid(pidFile, timeoutMs - 500);
    assert.ok(Date.now() - started < timeoutMs, 'fake elm started only after the timeout');
    assert.doesNotThrow(() => process.kill(pid, 0), 'fake elm is not running before the timeout');

    await rejection;

    // ...and is gone ~1s after the rejection
    await new Promise((resolve) => setTimeout(resolve, 1000));
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

// Linux-specific tests with fake spawnImpl
function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdin = new Writable({
    write(chunk, encoding, callback) {
      child.stdinWrites = child.stdinWrites || [];
      child.stdinWrites.push(chunk.toString());
      callback();
    },
  });
  child.kill = (signal) => {
    child.killSignals = child.killSignals || [];
    child.killSignals.push(signal || 'SIGTERM');
  };
  return child;
}

test('linux_argv_with_quote_escaping', async () => {
  const elmPath = "/tmp/test's/elm";
  const contextFile = "/tmp/context.cfg";
  let capturedArgs;

  const spawnImpl = (command, args, opts) => {
    assert.equal(command, 'script');
    capturedArgs = args;
    const child = fakeChild();
    // Immediate success
    setImmediate(() => {
      child.emit('exit', 0, null);
      child.emit('close');
    });
    return child;
  };

  await runElmInit({
    elmPath,
    contextFile,
    password: 'test',
    cwd: '/tmp',
    platform: 'linux',
    spawnImpl,
    log: () => {},
  });

  assert.deepEqual(capturedArgs, [
    '-q',
    '-e',
    '-c',
    "'/tmp/test'\\''s/elm' init -c '/tmp/context.cfg'",
    '/dev/null',
  ]);
});

test('linux_child_env_exact_keys', async () => {
  let capturedEnv;
  const cwd = '/home/test';

  const spawnImpl = (command, args, opts) => {
    capturedEnv = opts.env;
    const child = fakeChild();
    setImmediate(() => {
      child.emit('exit', 0, null);
      child.emit('close');
    });
    return child;
  };

  await runElmInit({
    elmPath: '/tmp/elm',
    contextFile: '/tmp/context.cfg',
    password: 'test',
    cwd,
    platform: 'linux',
    spawnImpl,
    log: () => {},
  });

  assert.deepEqual(Object.keys(capturedEnv).sort(), ['HOME', 'PATH', 'TERM']);
  assert.equal(capturedEnv.HOME, cwd);
  assert.equal(capturedEnv.TERM, 'dumb');
  assert.equal(capturedEnv.PATH, process.env.PATH);
});

test('linux_prompt_split_across_chunks', async () => {
  const password = 'test-password';
  let savedChild;

  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    savedChild = child;
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Pass'));
      child.stdout.emit('data', Buffer.from('word: '));
      // Record writes before chunk 3 to verify split-prompt triggered the write
      child.writesBeforeChunk3 = child.stdinWrites.length;
      child.stdout.emit('data', Buffer.from('Your password is set\n'));
      child.stdout.emit('data', Buffer.from('Done\n'));
      child.emit('exit', 0, null);
      child.emit('close');
    });
    return child;
  };

  await runElmInit({
    elmPath: '/tmp/elm',
    contextFile: '/tmp/context.cfg',
    password,
    cwd: '/tmp',
    platform: 'linux',
    spawnImpl,
    log: () => {},
  });

  // The split prompt "Context Pass" + "word: " should have already triggered the write
  assert.equal(savedChild.writesBeforeChunk3, 1);
  // And it should be the only write (not triggered again by "password" in chunk 3)
  assert.deepEqual(savedChild.stdinWrites, [password + '\n']);
});

test('linux_password_masked_in_logs', async () => {
  const password = 'secret123';
  const logLines = [];

  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      child.stdout.emit('data', Buffer.from(`You entered: ${password}\n`));
      child.stdout.emit('data', Buffer.from('Done\n'));
      child.emit('exit', 0, null);
      child.emit('close');
    });
    return child;
  };

  await runElmInit({
    elmPath: '/tmp/elm',
    contextFile: '/tmp/context.cfg',
    password,
    cwd: '/tmp',
    platform: 'linux',
    spawnImpl,
    log: (line) => logLines.push(line),
  });

  const fullLog = logLines.join('\n');
  assert.ok(!fullLog.includes(password), `Password should not appear in logs: ${fullLog}`);
  assert.ok(fullLog.includes('***'), 'Password should be masked with ***');
});

test('linux_exit_code_3_rejection', async () => {
  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      child.stdout.emit('data', Buffer.from('Wrong password\n'));
      child.emit('exit', 3, null);
      child.emit('close');
    });
    return child;
  };

  await assert.rejects(
    runElmInit({
      elmPath: '/tmp/elm',
      contextFile: '/tmp/context.cfg',
      password: 'test',
      cwd: '/tmp',
      platform: 'linux',
      spawnImpl,
      log: () => {},
    }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      assert.equal(err.message, 'elm init failed (exit 3)');
      return true;
    }
  );
});

test('linux_timeout_kills_child', async () => {
  let savedChild;
  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    savedChild = child;
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      // Never emit exit/close to trigger timeout
    });
    return child;
  };

  await assert.rejects(
    runElmInit({
      elmPath: '/tmp/elm',
      contextFile: '/tmp/context.cfg',
      password: 'test',
      cwd: '/tmp',
      platform: 'linux',
      spawnImpl,
      timeoutMs: 100,
      killGracePeriodMs: 50,
      log: () => {},
    }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      assert.equal(err.message, 'elm init timed out');
      return true;
    }
  );

  assert.deepEqual(savedChild.killSignals, ['SIGTERM']);
});

test('linux_stdin_epipe_ignored', async () => {
  // EPIPE + exit 0 → resolves
  const spawnImplSuccess = (command, args, opts) => {
    const child = fakeChild();
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      setTimeout(() => {
        const epipeError = new Error('write EPIPE');
        epipeError.code = 'EPIPE';
        child.stdin.emit('error', epipeError);
        child.emit('exit', 0, null);
        child.emit('close');
      }, 10);
    });
    return child;
  };

  await runElmInit({
    elmPath: '/tmp/elm',
    contextFile: '/tmp/context.cfg',
    password: 'test',
    cwd: '/tmp',
    platform: 'linux',
    spawnImpl: spawnImplSuccess,
    log: () => {},
  });

  // EPIPE + exit 2 → rejects with exit code
  const spawnImplFailure = (command, args, opts) => {
    const child = fakeChild();
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      setTimeout(() => {
        const epipeError = new Error('write EPIPE');
        epipeError.code = 'EPIPE';
        child.stdin.emit('error', epipeError);
        child.emit('exit', 2, null);
        child.emit('close');
      }, 10);
    });
    return child;
  };

  await assert.rejects(
    runElmInit({
      elmPath: '/tmp/elm',
      contextFile: '/tmp/context.cfg',
      password: 'test',
      cwd: '/tmp',
      platform: 'linux',
      spawnImpl: spawnImplFailure,
      log: () => {},
    }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      assert.equal(err.message, 'elm init failed (exit 2)');
      return true;
    }
  );
});

test('linux_stdin_non_epipe_error_rejects', async () => {
  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      setTimeout(() => {
        const otherError = new Error('other error');
        otherError.code = 'EOTHER';
        child.stdin.emit('error', otherError);
      }, 10);
    });
    return child;
  };

  await assert.rejects(
    runElmInit({
      elmPath: '/tmp/elm',
      contextFile: '/tmp/context.cfg',
      password: 'test',
      cwd: '/tmp',
      platform: 'linux',
      spawnImpl,
      killGracePeriodMs: 50,
      log: () => {},
    }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      assert.ok(err.message.includes('Failed to write'));
      return true;
    }
  );
});

test('linux_sigkill_after_grace_period', async () => {
  let savedChild;
  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    savedChild = child;
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      // Never emit close to simulate ignoring SIGTERM
    });
    return child;
  };

  await assert.rejects(
    runElmInit({
      elmPath: '/tmp/elm',
      contextFile: '/tmp/context.cfg',
      password: 'test',
      cwd: '/tmp',
      platform: 'linux',
      spawnImpl,
      timeoutMs: 50,
      killGracePeriodMs: 30,
      log: () => {},
    }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      assert.equal(err.message, 'elm init timed out');
      return true;
    }
  );

  // Wait for the grace period to elapse
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual(savedChild.killSignals, ['SIGTERM', 'SIGKILL']);
});

test('linux_no_sigkill_when_closed_in_grace', async () => {
  let savedChild;
  const spawnImpl = (command, args, opts) => {
    const child = fakeChild();
    savedChild = child;
    let killCount = 0;
    const originalKill = child.kill.bind(child);
    child.kill = (signal) => {
      originalKill(signal);
      killCount++;
      if (killCount === 1) {
        // Close immediately after SIGTERM
        setImmediate(() => {
          child.emit('exit', 143, null);
          child.emit('close');
        });
      }
    };
    setImmediate(() => {
      child.stdout.emit('data', Buffer.from('Context Password: \n'));
      // Will close after SIGTERM
    });
    return child;
  };

  await assert.rejects(
    runElmInit({
      elmPath: '/tmp/elm',
      contextFile: '/tmp/context.cfg',
      password: 'test',
      cwd: '/tmp',
      platform: 'linux',
      spawnImpl,
      timeoutMs: 50,
      killGracePeriodMs: 30,
      log: () => {},
    }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      return true;
    }
  );

  // Wait longer than killGracePeriodMs to ensure SIGKILL timer would have fired if not cleared
  await new Promise((resolve) => setTimeout(resolve, 80));
  // SIGKILL timer should have been cleared
  assert.deepEqual(savedChild.killSignals, ['SIGTERM']);
});

test('init_answers_feedback_prompts', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'test-password';
    // Simulates the real elm init with all prompts
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Enter Context Password: ' pw
echo
if [ "$pw" != "${password}" ]; then
  echo "Wrong password"
  exit 3
fi
echo "Select the Kubernetes Provider"
echo "  1. Amazon EKS"
echo "  2. Google GKE"
echo "  3. Azure AKS"
echo "> 4. Red Hat OpenShift"
echo "  5. SUSE Rancher"
echo "  6. Generic"
read -p 'possible values [1,2...6]: ' provider
if [ "$provider" != "4" ]; then
  echo "Wrong provider"
  exit 1
fi
read -p 'Choose action (Back [b], Next [n], Help [F1]): ' action1
if [ "$action1" != "n" ]; then
  echo "Expected n"
  exit 1
fi
read -p 'Choose action (Next [n], Help [F1]): ' action2
if [ "$action2" != "n" ]; then
  echo "Expected n"
  exit 1
fi
echo "elm init succeeded"
echo "Provide Feedback to SAP SE"
echo "  1. Fill out questionnaire"
echo "  2. Send analytics data only"
echo "> 3. No feedback"
read -p 'possible values [1,2,3]: ' feedback
if [ "$feedback" != "3" ]; then
  echo "Wrong feedback"
  exit 1
fi
exit 0
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await runElmInit({
      elmPath,
      contextFile,
      password,
      cwd: folder,
      timeoutMs: 10000,
      platform: process.platform,
      log: () => {},
    });
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_answers_follow_listed_numbers', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'test-password';
    // Simulates SAP reordering the options - Red Hat OpenShift is now option 5, No feedback is option 2
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Enter Context Password: ' pw
echo
if [ "$pw" != "${password}" ]; then
  echo "Wrong password"
  exit 3
fi
echo "Select the Kubernetes Provider"
echo "  1. Amazon EKS"
echo "  2. Google GKE"
echo "  3. Azure AKS"
echo "  4. SUSE Rancher"
echo "> 5. Red Hat OpenShift"
echo "  6. Generic"
read -p 'possible values [1,2...6]: ' provider
if [ "$provider" != "5" ]; then
  echo "Wrong provider, got $provider expected 5"
  exit 1
fi
read -p 'Choose action (Back [b], Next [n], Help [F1]): ' action1
if [ "$action1" != "n" ]; then
  echo "Expected n"
  exit 1
fi
read -p 'Choose action (Next [n], Help [F1]): ' action2
if [ "$action2" != "n" ]; then
  echo "Expected n"
  exit 1
fi
echo "elm init succeeded"
echo "Provide Feedback to SAP SE"
echo "  1. Fill out questionnaire"
echo "> 2. No feedback"
echo "  3. Send analytics data only"
read -p 'possible values [1,2,3]: ' feedback
if [ "$feedback" != "2" ]; then
  echo "Wrong feedback, got $feedback expected 2"
  exit 1
fi
exit 0
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await runElmInit({
      elmPath,
      contextFile,
      password,
      cwd: folder,
      timeoutMs: 10000,
      platform: process.platform,
      log: () => {},
    });
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('init_unknown_prompt_hands_over', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    const password = 'test-password';
    // Simulates elm asking for something unexpected
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Enter Context Password: ' pw
echo
read -p 'What is your favorite color? ' color
exit 0
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await assert.rejects(
      runElmInit({
        elmPath,
        contextFile,
        password,
        cwd: folder,
        timeoutMs: 1000,
        platform: process.platform,
        log: () => {},
      }),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('elm init asks something unexpected'));
        assert.ok(err.message.includes('continue by hand'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('fetch_falls_back_to_browser_then_caches', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-test-'));
  try {
    let putCalled = false;
    const mockS3 = {
      list: async (prefix) => {
        assert.equal(prefix, 'tools/elm/');
        return []; // No CLI in bucket
      },
      get: async (key, destFile) => {
        throw new Error('get should not be called when bucket is empty');
      },
      put: async (file, key) => {
        putCalled = true;
        assert.ok(key.startsWith('tools/elm/'));
        assert.ok(file.includes('elm'));
      },
    };

    const downloadInBrowser = async () => {
      const elmPath = join(folder, 'elm');
      await writeFile(elmPath, '#!/bin/sh\necho "browser elm"\n');
      await chmod(elmPath, 0o755);
      return elmPath;
    };

    const elmPath = await fetchElmCli(mockS3, folder, { downloadInBrowser });
    assert.ok(elmPath.endsWith('/elm'));
    assert.ok(putCalled, 'Should have cached the downloaded CLI to S3');
    const { stdout } = await execute(elmPath, []);
    assert.equal(stdout.trim(), 'browser elm');
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('fetch_without_fallback_still_reports_missing_cli', async () => {
  const mockS3 = {
    list: async (prefix) => [],
  };
  const folder = await mkdtemp(join(tmpdir(), 'elm-test-'));
  try {
    await assert.rejects(
      fetchElmCli(mockS3, folder),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('No elm CLI'));
        assert.ok(err.message.includes('tools/elm/'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});
