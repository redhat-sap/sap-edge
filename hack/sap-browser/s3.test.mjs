// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { s3Client, uploadBundle } from './s3.mjs';

test('put_command_line', async () => {
  const calls = [];
  const run = async (file, args, opts) => {
    calls.push({ file, args, opts });
    return { stdout: '', stderr: '' };
  };
  const client = s3Client({
    endpoint: 'https://s3.example.test:443',
    bucket: 'test-bucket',
    credentials: { accessKeyId: 'test-key', secretAccessKey: 'test-secret' },
    home: '/tmp/test-home',
    run,
  });
  await client.put('/tmp/source.zip', 'dest/key.zip');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].file, 'aws');
  assert.deepEqual(calls[0].args, [
    's3', 'cp',
    '/tmp/source.zip',
    's3://test-bucket/dest/key.zip',
    '--endpoint-url', 'https://s3.example.test:443',
    '--no-verify-ssl',
  ]);
});

test('child_env_is_minimal', async () => {
  process.env.SAP_TEST_SECRET = 'should-not-leak';
  let capturedEnv;
  const run = async (file, args, opts) => {
    capturedEnv = opts.env;
    return { stdout: '', stderr: '' };
  };
  const client = s3Client({
    endpoint: 'https://s3.example.test:443',
    bucket: 'test-bucket',
    credentials: { accessKeyId: 'test-key', secretAccessKey: 'test-secret' },
    home: '/tmp/test-home',
    run,
  });
  await client.put('/tmp/source.zip', 'dest/key.zip');
  assert.ok(capturedEnv);
  assert.deepEqual(Object.keys(capturedEnv).sort(), [
    'AWS_ACCESS_KEY_ID',
    'AWS_EC2_METADATA_DISABLED',
    'AWS_SECRET_ACCESS_KEY',
    'HOME',
    'PATH',
  ]);
  assert.equal(capturedEnv.AWS_ACCESS_KEY_ID, 'test-key');
  assert.equal(capturedEnv.AWS_SECRET_ACCESS_KEY, 'test-secret');
  assert.equal(capturedEnv.AWS_EC2_METADATA_DISABLED, 'true');
  assert.equal(capturedEnv.HOME, '/tmp/test-home');
  assert.equal(capturedEnv.PATH, process.env.PATH);
  assert.ok(!capturedEnv.SAP_TEST_SECRET);
  delete process.env.SAP_TEST_SECRET;
});

test('list_parses_json', async () => {
  const run = async (file, args) => {
    if (args[1] === 'list-objects-v2') {
      return {
        stdout: JSON.stringify({
          Contents: [
            { Key: 'prefix/file1.txt', LastModified: '2026-10-25T10:00:00Z', Size: 1024 },
            { Key: 'prefix/file2.txt', LastModified: '2026-10-26T10:00:00Z', Size: 2048 },
          ],
        }),
        stderr: '',
      };
    }
    return { stdout: '', stderr: '' };
  };
  const client = s3Client({
    endpoint: 'https://s3.example.test:443',
    bucket: 'test-bucket',
    credentials: { accessKeyId: 'test-key', secretAccessKey: 'test-secret' },
    home: '/tmp/test-home',
    run,
  });
  const objects = await client.list('prefix/');
  assert.equal(objects.length, 2);
  assert.equal(objects[0].key, 'prefix/file1.txt');
  assert.equal(objects[0].lastModified, '2026-10-25T10:00:00Z');
  assert.equal(objects[0].size, 1024);
  assert.equal(objects[1].key, 'prefix/file2.txt');
  assert.equal(objects[1].size, 2048);
});

test('errors_hide_stderr', async () => {
  const run = async () => {
    const error = new Error('Command failed');
    error.stderr = 'Error: access key is invalid';
    error.stdout = 'Some output with credentials';
    throw error;
  };
  const client = s3Client({
    endpoint: 'https://s3.example.test:443',
    bucket: 'test-bucket',
    credentials: { accessKeyId: 'test-key', secretAccessKey: 'test-secret' },
    home: '/tmp/test-home',
    run,
  });
  await assert.rejects(
    client.put('/tmp/source.zip', 'dest/key.zip'),
    (err) => {
      assert.equal(err.name, 'SetupError');
      assert.ok(!err.message.includes('access key'));
      assert.ok(!err.message.includes('credentials'));
      return true;
    }
  );
});

test('upload_bundle_key', async () => {
  const folder = await mkdtemp(join(tmpdir(), 's3-test-'));
  try {
    const file = join(folder, 'restricted-resources-test-bundle.zip');
    await writeFile(file, 'test content');
    let capturedKey;
    const mockS3 = {
      put: async (srcFile, key) => {
        assert.equal(srcFile, file);
        capturedKey = key;
      },
    };
    const key = await uploadBundle(mockS3, {
      file,
      s3Prefix: 'restricted-resources/my-cluster/',
      component: 'elm',
    });
    assert.equal(key, 'restricted-resources/my-cluster/elm/restricted-resources-test-bundle.zip');
    assert.equal(capturedKey, key);
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test('upload_bundle_rejects_other_names', async () => {
  const mockS3 = { put: async () => {} };
  for (const basename of ['context.cfg', '../x.zip', 'restricted-resources-x.tar']) {
    await assert.rejects(
      uploadBundle(mockS3, { file: `/tmp/${basename}`, s3Prefix: 'prefix/', component: 'elm' }),
      (err) => {
        assert.equal(err.name, 'SetupError');
        return true;
      }
    );
  }
  // Valid components
  await uploadBundle(mockS3, { file: '/tmp/restricted-resources-valid.zip', s3Prefix: 'prefix/', component: 'elm' });
  await uploadBundle(mockS3, { file: '/tmp/restricted-resources-valid.zip', s3Prefix: 'prefix/', component: 'edge-icell' });
  // Invalid component
  await assert.rejects(
    uploadBundle(mockS3, { file: '/tmp/restricted-resources-valid.zip', s3Prefix: 'prefix/', component: 'invalid' }),
    (err) => {
      assert.equal(err.name, 'SetupError');
      return true;
    }
  );
});
