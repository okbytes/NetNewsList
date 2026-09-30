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
  const { status = 200, body = {}, headers = {} } = respond(request);
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

test("writes a pending status and article pair atomically in the Articles zone", async () => {
  respond = (request) => request.path === "records/lookup"
    ? { body: { records: request.body.records.map((record) => notFound(record.recordName)) } }
    : { body: { records: request.body.operations.map((operation) => operation.record) } };

  await savePage(settings, { url: "https://example.com/post?utm_source=x", title: "A Post" });

  const id = articleID("https://example.com/post");
  const modify = requests[1].body;
  assert.deepEqual(modify.zoneID, { zoneName: "Articles" });
  assert.equal(modify.atomic, true);
  const [status, article] = modify.operations;
  assert.equal(status.operationType, "create");
  assert.equal(status.record.recordName, `s|${id}`);
  assert.equal(status.record.recordType, "ArticleStatus");
  assert.deepEqual(status.record.fields, { webFeedExternalID: { value: readingListFeedExternalID }, read: { value: "0" }, starred: { value: "0" } });
  assert.equal(article.operationType, "create");
  assert.equal(article.record.recordName, `a|${id}`);
  assert.equal(article.record.recordType, "Article");
  assert.deepEqual(article.record.fields.articleStatus.value, { recordName: `s|${id}`, zoneID: { zoneName: "Articles" }, action: "DELETE_SELF" });
  assert.equal(article.record.fields.webFeedURL.value, "netnewslist://reading-list");
  assert.equal(article.record.fields.uniqueID.value, "https://example.com/post");
  assert.equal(article.record.fields.url.value, "https://example.com/post");
  assert.equal(article.record.fields.externalURL.value, "https://example.com/post?utm_source=x");
  assert.equal(article.record.fields.title.value, "A Post");
  for (const contentField of ["contentHTMLData", "contentHTML", "contentTextData", "summary"]) {
    assert.equal(article.record.fields[contentField], undefined);
  }
});

test("a saved, archived page moves back to the inbox; a saved unread page is left alone", async () => {
  const id = articleID("https://example.com/post");
  let read = "1";
  respond = (request) => request.path === "records/lookup"
    ? { body: { records: [
      { recordName: `s|${id}`, recordType: "ArticleStatus", recordChangeTag: "tag-7", fields: { read: { value: read } } },
      { recordName: `a|${id}`, recordType: "Article", recordChangeTag: "tag-8", fields: {} }
    ] } }
    : { body: { records: request.body.operations.map((operation) => operation.record) } };

  assert.equal(await savePage(settings, { url: "https://example.com/post", title: "" }), "movedToInbox");
  const update = requests[1].body.operations[0];
  assert.equal(update.operationType, "update");
  assert.equal(update.record.recordChangeTag, "tag-7");
  assert.deepEqual(update.record.fields, { read: { value: "0" } });

  requests = [];
  read = "0";
  assert.equal(await savePage(settings, { url: "https://example.com/post", title: "" }), "alreadySaved");
  assert.equal(requests.length, 1);
});

test("a status left over from a delete is updated, keeping its star", async () => {
  const id = articleID("https://example.com/post");
  respond = (request) => request.path === "records/lookup"
    ? { body: { records: [
      { recordName: `s|${id}`, recordType: "ArticleStatus", recordChangeTag: "tag-1", fields: { read: { value: "1" }, starred: { value: "1" } } },
      notFound(`a|${id}`)
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

test("the queue drains in order once signed in, and record errors are reported", async () => {
  await enqueue({ url: "https://example.com/a", title: "A" });
  await enqueue({ url: "https://example.com/b", title: "B" });
  await enqueue({ url: "https://example.com/a", title: "A again" });
  assert.equal(await queueLength(), 2);

  respond = (request) => request.path === "records/lookup"
    ? { body: { records: request.body.records.map((record) => notFound(record.recordName)) } }
    : { body: { records: request.body.operations.map((operation) => operation.record) } };
  const { results, stoppedBy } = await drainQueue();
  assert.equal(stoppedBy, null);
  assert.deepEqual([...results.values()], ["saved", "saved"]);
  assert.equal(await queueLength(), 0);

  respond = (request) => request.path === "records/lookup"
    ? { body: { records: request.body.records.map((record) => notFound(record.recordName)) } }
    : { body: { records: [
      { recordName: "s|x", serverErrorCode: "ATOMIC_ERROR", reason: "Atomic failure" },
      { recordName: "a|x", serverErrorCode: "QUOTA_EXCEEDED", reason: "Out of space" }
    ] } };
  await enqueue({ url: "https://example.com/c", title: "C" });
  const second = await drainQueue();
  assert.equal(second.stoppedBy.serverErrorCode, "QUOTA_EXCEEDED");
  assert.equal(await queueLength(), 1);
});

test("the sign-in URL comes from an unauthenticated request", async () => {
  respond = () => ({ status: 421, body: { serverErrorCode: "AUTHENTICATION_REQUIRED", redirectURL: "https://idmsa.apple.com/sign-in" } });
  assert.equal(await signInURL(settings), "https://idmsa.apple.com/sign-in");
  assert.equal(requests[0].url.searchParams.get("ckWebAuthToken"), null);
  assert.equal(requests[0].path, "users/current");
  assert.equal(storage.get("webAuthToken"), "token+1/=");
});
