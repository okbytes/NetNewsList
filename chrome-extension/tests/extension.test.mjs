// Run with: node --test chrome-extension/tests/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { canonicalize } from "../lib/canonicalize.js";
import { md5 } from "../lib/md5.js";
import { articleID, readingListFeedURL } from "../lib/records.js";

const vectorsURL = new URL("../../Modules/Account/Tests/AccountTests/Resources/url-canonicalization.json", import.meta.url);
const { vectors } = JSON.parse(readFileSync(vectorsURL, "utf8"));

test("canonicalizes like the apps", () => {
  assert.ok(vectors.length > 0);
  for (const { input, output } of vectors) {
    assert.equal(canonicalize(input), output, `input: ${JSON.stringify(input)}`);
  }
});

test("md5 matches the standard digest of the UTF-8 bytes", () => {
  const samples = ["", "a", "abc", "netnewslist://reading-list", "café ✓ 🍁", "x".repeat(55), "y".repeat(56), "z".repeat(64), "w".repeat(1000)];
  for (const sample of samples) {
    assert.equal(md5(sample), createHash("md5").update(sample, "utf8").digest("hex"), `sample: ${JSON.stringify(sample)}`);
  }
});

test("article IDs are md5 of the feed ID, a space and the canonical URL", () => {
  const canonical = canonicalize("https://Example.com/post/?utm_source=x");
  assert.equal(canonical, "https://example.com/post");
  const expected = createHash("md5").update(`${readingListFeedURL} ${canonical}`, "utf8").digest("hex");
  assert.equal(articleID(canonical), expected);
});
