// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { after, before, test } from 'node:test';
import { chromium } from 'playwright';
import { keepDownloads } from './downloads.mjs';

let browser;
before(async () => {
  browser = await chromium.launch({ headless: true, channel: process.env.SAP_BROWSER_TEST_CHANNEL || undefined });
});
after(async () => { await browser?.close(); });

// An empty zip archive (end of central directory record only)
const EMPTY_ZIP = 'UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA==';
const ZIP_NAME = 'restricted-resources-Edge_Lifecycle_Management-1.65.0.zip';

async function waitUntil(condition, ms = 5000) {
  for (const end = Date.now() + ms; Date.now() < end; await delay(50)) {
    if (condition()) return;
  }
  throw new Error('condition not met in time');
}

async function download(page, name) {
  await page.setContent(`<a download="${name}" href="data:application/zip;base64,${EMPTY_ZIP}">zip</a>`);
  await Promise.all([page.waitForEvent('download'), page.click('a')]);
}

test('keeps a download under its suggested name, also from a page opened later', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sap-browser-downloads-'));
  const context = await browser.newContext();
  try {
    const logs = [];
    const first = await context.newPage();
    await keepDownloads(context, join(dir, 'downloads'), (line) => logs.push(line));
    await download(first, ZIP_NAME);
    await download(await context.newPage(), 'second.zip');

    const kept = [join(dir, 'downloads', ZIP_NAME), join(dir, 'downloads', 'second.zip')];
    await waitUntil(() => kept.every((file) => logs.includes(`Saved download: ${file}`)));
    for (const file of kept) {
      assert.deepEqual(await readFile(file), Buffer.from(EMPTY_ZIP, 'base64'));
    }
    assert.equal((await stat(join(dir, 'downloads'))).mode & 0o777, 0o700);
  } finally {
    await context.close();
    await rm(dir, { recursive: true, force: true });
  }
});
