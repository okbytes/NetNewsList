// Remote mode: save pages straight into iCloud, for a machine without the app.
// Pages wait in a local queue until they are written, so a save made while
// signed out or offline isn't lost.

import { canonicalize } from "./canonicalize.js";
import { CloudKitError, RecordError, SignInRequiredError, lookupRecords, modifyRecords } from "./cloudkit.js";
import { articleID, articleRecordName, moveToQueueOperation, saveOperations, statusRecordName } from "./records.js";
import { loadSettings } from "./settings.js";

// How many dropped pages the options page lists.
const droppedLimit = 50;

export class NotAWebPageError extends Error {
  constructor() {
    super("Only web pages can be saved.");
    this.name = "NotAWebPageError";
  }
}

function pageRecordNames(canonicalURL) {
  const id = articleID(canonicalURL);
  return [statusRecordName(id), articleRecordName(id)];
}

// CloudKit doesn't promise to answer a lookup in the order it was asked, so each
// record is found by name. Only NOT_FOUND means the record doesn't exist.
function lookedUp(lookup, recordName) {
  const record = (lookup.records || []).find((candidate) => candidate.recordName === recordName);
  if (!record) {
    throw new CloudKitError("MISSING_RECORD", `iCloud’s answer left out ${recordName}`);
  }
  if (record.serverErrorCode === "NOT_FOUND") {
    return null;
  }
  if (record.serverErrorCode) {
    throw new CloudKitError(record.serverErrorCode, record.reason);
  }
  return record;
}

// Writes one page. Resolves to "saved", "movedToQueue" or "alreadySaved".
export async function savePage(settings, page) {
  const canonicalURL = canonicalize(page.url);
  if (!canonicalURL) {
    throw new NotAWebPageError();
  }
  const id = articleID(canonicalURL);
  const recordNames = pageRecordNames(canonicalURL);
  const lookup = await lookupRecords(settings, recordNames);
  const [status, article] = recordNames.map((recordName) => lookedUp(lookup, recordName));

  if (article) {
    if (status && status.fields?.read?.value === "1") {
      await modifyRecords(settings, [moveToQueueOperation(status)]);
      return "movedToQueue";
    }
    return "alreadySaved";
  }

  const title = (page.title || "").trim();
  const pageURL = String(page.url).trim();
  // Queued pages carry the time they were saved; one queued without it is dated now.
  const dateSaved = Number.isFinite(page.addedAt) ? page.addedAt : Date.now();
  await modifyRecords(settings, saveOperations({ id, canonicalURL, pageURL, title, dateSaved, existingStatus: status }));
  return "saved";
}

// Every read-modify-write of the stored queue and the dropped list goes through
// this chain, one at a time, so a page enqueued while a drain removes another
// can't be lost.
let lastQueueChange = Promise.resolve();

function serially(operation) {
  const result = lastQueueChange.then(operation, operation);
  lastQueueChange = result.catch(() => {});
  return result;
}

async function storedQueue() {
  const { queue } = await chrome.storage.local.get("queue");
  return queue || [];
}

export function enqueue(page) {
  return serially(async () => {
    const items = await storedQueue();
    if (!items.some((item) => item.url === page.url)) {
      items.push({ url: page.url, title: page.title || "", addedAt: Date.now() });
      await chrome.storage.local.set({ queue: items });
    }
  });
}

// Removes a page from the queue; with `drop`, also lists it as dropped.
function removeFromQueue(url, drop = null) {
  return serially(async () => {
    const changes = { queue: (await storedQueue()).filter((item) => item.url !== url) };
    if (drop) {
      const { dropped } = await chrome.storage.local.get("dropped");
      changes.dropped = [drop, ...(dropped || [])].slice(0, droppedLimit);
    }
    await chrome.storage.local.set(changes);
  });
}

export async function queueLength() {
  return (await storedQueue()).length;
}

// Pages that were taken out of the queue unsaved, newest first:
// [{ url, title, reason, droppedAt }].
export async function droppedPages() {
  const { dropped } = await chrome.storage.local.get("dropped");
  return dropped || [];
}

export function clearDroppedPages() {
  return serially(() => chrome.storage.local.remove("dropped"));
}

// A page is dropped only when it can never be written as it is: it isn't a web
// page, or iCloud rejected one of its own records as invalid. Anything else (a
// request iCloud refused as a whole, which would fail every page alike; signed
// out; offline; out of space) stops the drain and keeps the queue.
function isUnsavable(error, item) {
  if (error instanceof NotAWebPageError) {
    return true;
  }
  return error instanceof RecordError
    && error.serverErrorCode === "BAD_REQUEST"
    && pageRecordNames(canonicalize(item.url)).includes(error.recordName);
}

let draining = null;
let drainingAgain = null;

// Writes queued pages, oldest first. Stops at the first page that can't be
// written for a reason that would stop the rest too (signed out, offline).
// Resolves to { results: Map(url -> outcome), stoppedBy: Error | null }.
//
// A call made while a drain is running gets one more drain chained after it, so
// a page queued meanwhile, or a sign-in that lands meanwhile, is acted on as soon
// as the running one finishes rather than at the next save. Its results include
// both drains'.
export function drainQueue() {
  if (!draining) {
    draining = drain().finally(() => {
      draining = null;
    });
    return draining;
  }
  drainingAgain ??= draining.then(async (first) => {
    drainingAgain = null;
    const second = await drainQueue();
    return { results: new Map([...first.results, ...second.results]), stoppedBy: second.stoppedBy };
  });
  return drainingAgain;
}

async function drain() {
  const results = new Map();
  let stoppedBy = null;
  try {
    const settings = await loadSettings();
    for (const item of await storedQueue()) {
      try {
        results.set(item.url, await savePage(settings, item));
        await removeFromQueue(item.url);
      } catch (error) {
        if (!isUnsavable(error, item)) {
          throw error;
        }
        results.set(item.url, error);
        await removeFromQueue(item.url, { url: item.url, title: item.title || "", reason: error.message, droppedAt: Date.now() });
      }
    }
  } catch (error) {
    stoppedBy = error;
  }
  // An empty queue says nothing about the sign-in, so it leaves the state alone.
  // A drain always resolves, so a drain chained after it always runs.
  try {
    if (results.size > 0 || stoppedBy) {
      await chrome.storage.local.set({ lastError: stoppedBy ? stoppedBy.message : null, needsSignIn: stoppedBy instanceof SignInRequiredError });
    }
  } catch (error) {
    stoppedBy ??= error;
  }
  return { results, stoppedBy };
}
