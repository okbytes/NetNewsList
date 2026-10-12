// The records the apps write when a page is saved, before it is extracted:
// an ArticleStatus record and an Article record with no content, in the
// Articles zone of the private database. See Technotes/NetNewsList/Plan.md, 3.4.
//
// Every field names its type, as CloudKit Web Services' Types reference describes:
// STRING, REFERENCE, and TIMESTAMP (milliseconds since 1970).

import { md5 } from "./md5.js";

export const readingListFeedURL = "netnewslist://reading-list";
export const readingListFeedExternalID = md5(readingListFeedURL);
export const zoneID = { zoneName: "Articles" };

export function articleID(canonicalURL) {
  return md5(`${readingListFeedURL} ${canonicalURL}`);
}

export function statusRecordName(id) {
  return `s|${id}`;
}

export function articleRecordName(id) {
  return `a|${id}`;
}

function string(value) {
  return { value, type: "STRING" };
}

function statusRecord(id, existingStatus) {
  const record = {
    recordType: "ArticleStatus",
    recordName: statusRecordName(id),
    fields: {
      webFeedExternalID: string(readingListFeedExternalID),
      read: string("0"),
      starred: string(existingStatus?.fields?.starred?.value ?? "0")
    }
  };
  if (existingStatus) {
    record.recordChangeTag = existingStatus.recordChangeTag;
  }
  return record;
}

// datePublished is the time the page was saved. The apps sort and show "Date Saved"
// by it, and it syncs, unlike the time each device happens to fetch the record.
function pendingArticleRecord(id, canonicalURL, pageURL, title, dateSaved) {
  const fields = {
    articleStatus: { value: { recordName: statusRecordName(id), zoneID, action: "DELETE_SELF" }, type: "REFERENCE" },
    webFeedURL: string(readingListFeedURL),
    uniqueID: string(canonicalURL),
    url: string(canonicalURL)
  };
  if (pageURL && pageURL !== canonicalURL) {
    fields.externalURL = string(pageURL);
  }
  if (title) {
    fields.title = string(title);
  }
  fields.datePublished = { value: dateSaved, type: "TIMESTAMP" };
  return { recordType: "Article", recordName: articleRecordName(id), fields };
}

// Operations for a page that isn't saved yet. A status record left over from an
// earlier delete is updated rather than created, so the create can't collide with it.
// Only this create sets the saved date: a page that is already saved keeps its own.
export function saveOperations({ id, canonicalURL, pageURL, title, dateSaved, existingStatus }) {
  return [
    { operationType: existingStatus ? "update" : "create", record: statusRecord(id, existingStatus) },
    { operationType: "create", record: pendingArticleRecord(id, canonicalURL, pageURL, title, dateSaved) }
  ];
}

// Saving a page that is already saved moves it back to the Queue, as in the apps.
// Only the status changes; the Article record, and so its saved date, is left alone.
export function moveToQueueOperation(existingStatus) {
  return {
    operationType: "update",
    record: {
      recordType: "ArticleStatus",
      recordName: existingStatus.recordName,
      recordChangeTag: existingStatus.recordChangeTag,
      fields: { read: string("0") }
    }
  };
}
