// SPDX-FileCopyrightText: 2026 SAP edge team
// SPDX-License-Identifier: Apache-2.0

import { mkdir } from 'node:fs/promises';
import { basename, join } from 'node:path';

// Keep the files downloaded in a browser context (for example the ELM and EIC
// restricted-resources zips during an inspect walkthrough): Playwright deletes
// downloads when the context closes. Covers every page of the context,
// including pages opened later.
export async function keepDownloads(context, directory, log = console.log) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const watch = (page) => page.on('download', async (download) => {
    const name = basename(download.suggestedFilename()) || 'download';
    const target = join(directory, name);
    try {
      await download.saveAs(target);
      log(`Saved download: ${target}`);
    } catch (error) {
      log(`Download ${name} not saved: ${error.message}`);
    }
  });
  context.pages().forEach(watch);
  context.on('page', watch);
}
