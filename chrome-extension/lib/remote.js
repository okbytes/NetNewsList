// Remote mode: save pages straight into iCloud, for a machine without the app.
// Pages wait in a local queue until they are written, so a save made while
// signed out or offline isn't lost.

import { canonicalize } from "./canonicalize.js";
import { CloudKitError, SignInRequiredError, lookupRecords, modifyRecords } from "./cloudkit.js";
import { articleID, articleRecordName, moveToInboxOperation, saveOperations, statusRecordName } from "./records.js";
import { loadSettings } from "./settings.js";

export class NotAWebPageError extends Error {
  constructor() {
    super("Only web pages can be saved.");
    this.name = "NotAWebPageError";
  }
}

// Writes one page. Resolves to "saved", "movedToInbox" or "alreadySaved".
export async function savePage(settings, page) {
  const canonicalURL = canonicalize(page.url);
  if (!canonicalURL) {
    throw new NotAWebPageError();
  }
  const id = articleID(canonicalURL);
  const lookup = await lookupRecords(settings, [statusRecordName(id), articleRecordName(id)]);
  const [status, article] = (lookup.records || []).map((record) => (record.serverErrorCode ? null : record));

  if (article) {
    if (status && status.fields?.read?.value === "1") {
      await modifyRecords(settings, [moveToInboxOperation(status)]);
      return "movedToInbox";
    }
    return "alreadySaved";
  }

  const title = (page.title || "").trim();
  const pageURL = String(page.url).trim();
  await modifyRecords(settings, saveOperations({ id, canonicalURL, pageURL, title, existingStatus: status }));
  return "saved";
}

async function queue() {
  const { queue } = await chrome.storage.local.get("queue");
  return queue || [];
}

async function setQueue(items) {
  await chrome.storage.local.set({ queue: items });
}

export async function enqueue(page) {
  const items = await queue();
  if (!items.some((item) => item.url === page.url)) {
    items.push({ url: page.url, title: page.title || "", addedAt: Date.now() });
    await setQueue(items);
  }
}

export async function queueLength() {
  return (await queue()).length;
}

let draining = null;

// Writes queued pages, oldest first. Stops at the first page that can't be
// written for a reason that would stop the rest too (signed out, offline).
// Resolves to { results: Map(url -> outcome), stoppedBy: Error | null }.
export function drainQueue() {
  if (!draining) {
    draining = drain().finally(() => {
      draining = null;
    });
  }
  return draining;
}

async function drain() {
  const settings = await loadSettings();
  const results = new Map();
  let stoppedBy = null;
  for (const item of await queue()) {
    try {
      results.set(item.url, await savePage(settings, item));
      await setQueue((await queue()).filter((queued) => queued.url !== item.url));
    } catch (error) {
      if (error instanceof NotAWebPageError || (error instanceof CloudKitError && error.serverErrorCode === "BAD_REQUEST")) {
        // This page can never be written; drop it and keep going.
        results.set(item.url, error);
        await setQueue((await queue()).filter((queued) => queued.url !== item.url));
        continue;
      }
      stoppedBy = error;
      break;
    }
  }
  await chrome.storage.local.set({ lastError: stoppedBy ? stoppedBy.message : null, needsSignIn: stoppedBy instanceof SignInRequiredError });
  return { results, stoppedBy };
}
