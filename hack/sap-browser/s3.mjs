// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { execFile } from 'node:child_process';
import { basename } from 'node:path';
import { promisify } from 'node:util';
import { SetupError } from './inputs.mjs';

const execute = promisify(execFile);

export function s3Client({ endpoint, bucket, credentials, home, run = execute }) {
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    AWS_ACCESS_KEY_ID: credentials.accessKeyId,
    AWS_SECRET_ACCESS_KEY: credentials.secretAccessKey,
    AWS_EC2_METADATA_DISABLED: 'true',
  };

  const baseArgs = ['--endpoint-url', endpoint, '--no-verify-ssl'];

  async function awsCommand(args) {
    try {
      return await run('aws', args, { env });
    } catch (error) {
      // Never expose stdout/stderr which may contain credentials
      throw new SetupError('S3 operation failed. Check endpoint, bucket and permissions.');
    }
  }

  return {
    async put(file, key) {
      await awsCommand(['s3', 'cp', file, `s3://${bucket}/${key}`, ...baseArgs]);
    },

    async list(prefix) {
      const { stdout } = await awsCommand(['s3api', 'list-objects-v2', '--bucket', bucket, '--prefix', prefix, '--output', 'json', ...baseArgs]);
      const data = JSON.parse(stdout);
      return (data.Contents || []).map((obj) => ({
        key: obj.Key,
        lastModified: obj.LastModified,
        size: obj.Size,
      }));
    },

    async get(key, file) {
      await awsCommand(['s3', 'cp', `s3://${bucket}/${key}`, file, ...baseArgs]);
    },
  };
}

export async function uploadBundle(s3, { file, s3Prefix, component }) {
  const name = basename(file);
  if (!/^restricted-resources-[A-Za-z0-9_.-]+\.zip$/.test(name)) {
    throw new SetupError('Bundle filename must match restricted-resources-*.zip pattern.');
  }
  if (!['elm', 'edge-icell'].includes(component)) {
    throw new SetupError('Component must be either "elm" or "edge-icell".');
  }
  const key = `${s3Prefix}${component}/${name}`;
  await s3.put(file, key);
  return key;
}
