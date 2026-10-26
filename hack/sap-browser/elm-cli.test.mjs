// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
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

test('init_times_out', async () => {
  const folder = await mkdtemp(join(tmpdir(), 'elm-init-test-'));
  try {
    const elmPath = join(folder, 'fake-elm');
    const contextFile = join(folder, 'context.cfg');
    await writeFile(elmPath, `#!/bin/bash
read -rs -p 'Context Password: ' pw
echo
sleep 10
exit 0
`);
    await chmod(elmPath, 0o755);
    await writeFile(contextFile, 'test-context');

    await assert.rejects(
      runElmInit({
        elmPath,
        contextFile,
        password: 'test',
        cwd: folder,
        timeoutMs: 500,
        platform: process.platform,
      }),
      (err) => {
        assert.equal(err.name, 'SetupError');
        assert.ok(err.message.includes('elm init timed out'));
        return true;
      }
    );
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});
