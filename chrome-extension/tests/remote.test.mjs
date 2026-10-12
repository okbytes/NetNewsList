// Run with: node --test chrome-extension/tests/*.test.mjs
// Exercises the CloudKit client and the save flow against a fake chrome.storage
// and a fake CloudKit, including the single-use web auth token.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

const storage = new Map();
globalThis.chrome = {
  runtime: { getURL: (path) => `chrome-extension://test/${path}` },
  storage: {
    local: {
      async get(keys) {
        const list = Array.isArray(keys) ? keys : [keys];
        return Object.fromEntries(list.filter((key) => storage.has(key)).map((key) => [key, structuredClone(storage.get(key))]));
      },
      async set(values) {
        for (const [key, value] of Object.entries(values)) {
          storage.set(key, structuredClone(value));
        }
      },
      async remove(key) {
        storage.delete(key);
      }
    }
  }
};

let requests = [];
let respond = () => ({ status: 500, body: {} });
globalThis.fetch = async (input, init = {}) => {
  const url = new URL(String(input));
  if (url.protocol === "chrome-extension:") {
    return { ok: false, status: 404, json: async () => ({}), headers: new Headers() };
  }
  const request = { url, path: url.pathname.split("/private/")[1], body: init.body ? JSON.parse(init.body) : null };
  requests.push(request);
  const { status = 200, body = {}, headers = {} } = await respond(request);
  return { ok: status >= 200 && status < 300, status, json: async () => body, headers: new Headers(headers) };
};

const { savePage, enqueue, drainQueue, queueLength } = await import("../lib/remote.js");
const { signInURL, SignInRequiredError } = await import("../lib/cloudkit.js");
const { articleID, readingListFeedExternalID } = await import("../lib/records.js");

const settings = { containerID: "iCloud.example.Test", environment: "development", apiToken: "api-token", callbackURL: "https://example.com" };

beforeEach(async () => {
  storage.clear();
  storage.set("settings", settings);
  storage.set("webAuthToken", "token+1/=");
  requests = [];
});

function notFound(recordName) {
  return { recordName, serverErrorCode: "NOT_FOUND", reason: "Record not found" };
}

function savesEverything(request) {
  return request.path === "records/lookup"
    ? { body: { records: request.body.records.map((record) => notFound(record.recordName)) } }
    : { body: { records: request.body.operations.map((operation) => operation.record) } };
}

test("sends the API token and the encoded web auth token, and keeps the replacement token", async () => {
  respond = (request) => request.path === "records/lookup"
    ? { body: { records: request.body.records.map((record) => notFound(record.recordName)) }, headers: { "X-Apple-CloudKit-Web-Auth-Token": "token-2" } }
    : { body: { records: request.body.operations.map((operation) => operation.record) }, headers: { "X-Apple-CloudKit-Web-Auth-Token": "token-3" } };

  assert.equal(await savePage(settings, { url: "https://Example.com/post/?utm_source=x", title: " A Post " }), "saved");

  assert.equal(requests[0].url.searchParams.get("ckAPIToken"), "api-token");
  assert.match(requests[0].url.search, /ckWebAuthToken=token%2B1%2F%3D/);
  assert.equal(requests[1].url.searchParams.get("ckWebAuthToken"), "token-2");
  assert.equal(storage.get("webAuthToken"), "token-3");
  assert.ok(requests[0].url.pathname.endsWith("/iCloud.example.Test/development/private/records/lookup"));
});

test("writes a pending status and article pair atomically in the Articles zone, dated when the page was saved", async () => {
  respond = savesEverything;
  const savedAt = Date.UTC(2026, 9, 1, 12, 30);

  await savePage(settings, { url: "https://example.com/post?utm_source=x", title: "A Post", addedAt: savedAt });

  const id = articleID("https://example.com/post");
  const modify = requests[1].body;
  assert.deepEqual(modify.zoneID, { zoneName: "Articles" });
  assert.equal(modify.atomic, true);
  const [status, article] = modify.operations;
  assert.equal(status.operationType, "create");
  assert.equal(status.record.recordName, `s|${id}`);
  assert.equal(status.record.recordType, "ArticleStatus");
  assert.deepEqual(status.record.fields, {
    webFeedExternalID: { value: readingListFeedExternalID, type: "STRING" },
    read: { value: "0", type: "STRING" },
    starred: { value: "0", type: "STRING" }
  });
  assert.equal(article.operationType, "create");
  assert.equal(article.record.recordName, `a|${id}`);
  assert.equal(article.record.recordType, "Article");
  // No content fields: the record arrives on the devices as a page still to extract.
  assert.deepEqual(article.record.fields, {
    articleStatus: { value: { recordName: `s|${id}`, zoneID: { zoneName: "Articles" }, action: "DELETE_SELF" }, type: "REFERENCE" },
    webFeedURL: { value: "netnewslist://reading-list", type: "STRING" },
    uniqueID: { value: "https://example.com/post", type: "STRING" },
    url: { value: "https://example.com/post", type: "STRING" },
    externalURL: { value: "https://example.com/post?utm_source=x", type: "STRING" },
    title: { value: "A Post", type: "STRING" },
    datePublished: { value: savedAt, type: "TIMESTAMP" }
  });
});

test("a saved, archived page moves back to the Queue; a saved unread page is left alone", async () => {
  const id = articleID("https://example.com/post");
  let read = "1";
  respond = (request) => request.path === "records/lookup"
    ? { body: { records: [
      { recordName: `s|${id}`, recordType: "ArticleStatus", recordChangeTag: "tag-7", fields: { read: { value: read } } },
      { recordName: `a|${id}`, recordType: "Article", recordChangeTag: "tag-8", fields: {} }
    ] } }
    : { body: { records: request.body.operations.map((operation) => operation.record) } };

  assert.equal(await savePage(settings, { url: "https://example.com/post", title: "" }), "movedToQueue");
  const update = requests[1].body.operations[0];
  assert.equal(update.operationType, "update");
  assert.equal(update.record.recordChangeTag, "tag-7");
  assert.deepEqual(update.record.fields, { read: { value: "0", type: "STRING" } });

  requests = [];
  read = "0";
  assert.equal(await savePage(settings, { url: "https://example.com/post", title: "" }), "alreadySaved");
  assert.equal(requests.length, 1);
});

test("a status left over from a delete is updated, keeping its star, whatever order the lookup answers in", async () => {
  const id = articleID("https://example.com/post");
  respond = (request) => request.path === "records/lookup"
    ? { body: { records: [
      notFound(`a|${id}`),
      { recordName: `s|${id}`, recordType: "ArticleStatus", recordChangeTag: "tag-1", fields: { read: { value: "1" }, starred: { value: "1" } } }
    ] } }
    : { body: { records: request.body.operations.map((operation) => operation.record) } };

  await savePage(settings, { url: "https://example.com/post", title: "" });
  const [status, article] = requests[1].body.operations;
  assert.equal(status.operationType, "update");
  assert.equal(status.record.recordChangeTag, "tag-1");
  assert.equal(status.record.fields.read.value, "0");
  assert.equal(status.record.fields.starred.value, "1");
  assert.equal(article.operationType, "create");
});

test("an expired sign-in keeps the page queued and asks for sign-in", async () => {
  respond = () => ({ status: 421, body: { serverErrorCode: "AUTHENTICATION_REQUIRED", redirectURL: "https://idmsa.apple.com/sign-in" } });
  await enqueue({ url: "https://example.com/a", title: "A" });
  const { stoppedBy } = await drainQueue();
  assert.ok(stoppedBy instanceof SignInRequiredError);
  assert.equal(await queueLength(), 1);
  assert.equal(storage.get("webAuthToken"), undefined);
  assert.equal(storage.get("needsSignIn"), true);
});

test("the queue drains in order once signed in", async () => {
  await enqueue({ url: "https://example.com/a", title: "A" });
  await enqueue({ url: "https://example.com/b", title: "B" });
  await enqueue({ url: "https://example.com/a", title: "A again" });
  assert.equal(await queueLength(), 2);

  respond = savesEverything;
  const { results, stoppedBy } = await drainQueue();
  assert.equal(stoppedBy, null);
  assert.deepEqual([...results.keys()], ["https://example.com/a", "https://example.com/b"]);
  assert.deepEqual([...results.values()], ["saved", "saved"]);
  assert.equal(await queueLength(), 0);
});

test("pages saved at the same moment, even while the queue drains, are all kept", async () => {
  respond = savesEverything;
  const urls = ["a", "b", "c", "d"].map((name) => `https://example.com/${name}`);
  await enqueue({ url: urls[0], title: "" });

  await Promise.all([drainQueue(), ...urls.slice(1).map((url) => enqueue({ url, title: "" }))]);
  await drainQueue();

  const written = requests.filter((request) => request.path === "records/modify").map((request) => request.body.operations[1].record.fields.url.value);
  assert.deepEqual(written.sort(), urls);
  assert.equal(await queueLength(), 0);
});

test("a page saved while the queue drains is written as soon as that drain ends", async () => {
  let lookupStarted;
  let releaseLookup;
  const started = new Promise((resolve) => {
    lookupStarted = resolve;
  });
  const released = new Promise((resolve) => {
    releaseLookup = resolve;
  });
  respond = async (request) => {
    if (request.path === "records/lookup" && requests.length === 1) {
      lookupStarted();
      await released;
    }
    return savesEverything(request);
  };

  await enqueue({ url: "https://example.com/a", title: "A" });
  const first = drainQueue();
  await started;
  await enqueue({ url: "https://example.com/b", title: "B" });
  const second = drainQueue();
  releaseLookup();

  const { results, stoppedBy } = await second;
  assert.equal(stoppedBy, null);
  assert.equal(results.get("https://example.com/a"), "saved");
  assert.equal(results.get("https://example.com/b"), "saved");
  assert.equal(await queueLength(), 0);
  await first;
});

test("only a page whose own record iCloud rejects is dropped, and it is listed; other failures keep the queue", async () => {
  const id = articleID("https://example.com/a");
  await enqueue({ url: "https://example.com/a", title: "A" });

  // A request refused as a whole (a wrong zone or field shape would fail every page).
  respond = (request) => request.path === "records/lookup"
    ? savesEverything(request)
    : { status: 400, body: { serverErrorCode: "BAD_REQUEST", reason: "Unknown zone" } };
  const refused = await drainQueue();
  assert.equal(refused.stoppedBy?.serverErrorCode, "BAD_REQUEST");
  assert.equal(await queueLength(), 1);
  assert.equal(storage.get("lastError"), "Unknown zone (BAD_REQUEST)");

  respond = (request) => request.path === "records/lookup"
    ? savesEverything(request)
    : { body: { records: [
      { recordName: `s|${id}`, serverErrorCode: "ATOMIC_ERROR", reason: "Atomic failure" },
      { recordName: `a|${id}`, serverErrorCode: "QUOTA_EXCEEDED", reason: "Out of space" }
    ] } };
  const full = await drainQueue();
  assert.equal(full.stoppedBy?.serverErrorCode, "QUOTA_EXCEEDED");
  assert.equal(await queueLength(), 1);

  respond = (request) => request.path === "records/lookup"
    ? savesEverything(request)
    : { body: { records: [
      { recordName: `s|${id}`, serverErrorCode: "ATOMIC_ERROR", reason: "Atomic failure" },
      { recordName: `a|${id}`, serverErrorCode: "BAD_REQUEST", reason: "Title too long" }
    ] } };
  const rejected = await drainQueue();
  assert.equal(rejected.stoppedBy, null);
  assert.equal(rejected.results.get("https://example.com/a").message, "Title too long (BAD_REQUEST)");
  assert.equal(await queueLength(), 0);
  assert.deepEqual(storage.get("dropped").map(({ url, reason }) => ({ url, reason })), [{ url: "https://example.com/a", reason: "Title too long (BAD_REQUEST)" }]);
});

test("the sign-in URL comes from an unauthenticated request", async () => {
  respond = () => ({ status: 421, body: { serverErrorCode: "AUTHENTICATION_REQUIRED", redirectURL: "https://idmsa.apple.com/sign-in" } });
  assert.equal(await signInURL(settings), "https://idmsa.apple.com/sign-in");
  assert.equal(requests[0].url.searchParams.get("ckWebAuthToken"), null);
  assert.equal(requests[0].path, "users/current");
  assert.equal(storage.get("webAuthToken"), "token+1/=");
});
