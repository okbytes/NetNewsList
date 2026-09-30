// The records the apps write when a page is saved, before it is extracted:
// an ArticleStatus record and an Article record with no content, in the
// Articles zone of the private database. See Technotes/NetNewsList/Plan.md, 3.4.

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

function statusRecord(id, existingStatus) {
  const record = {
    recordType: "ArticleStatus",
    recordName: statusRecordName(id),
    fields: {
      webFeedExternalID: { value: readingListFeedExternalID },
      read: { value: "0" },
      starred: { value: existingStatus?.fields?.starred?.value ?? "0" }
    }
  };
  if (existingStatus) {
    record.recordChangeTag = existingStatus.recordChangeTag;
  }
  return record;
}

function pendingArticleRecord(id, canonicalURL, pageURL, title) {
  const fields = {
    articleStatus: { value: { recordName: statusRecordName(id), zoneID, action: "DELETE_SELF" } },
    webFeedURL: { value: readingListFeedURL },
    uniqueID: { value: canonicalURL },
    url: { value: canonicalURL }
  };
  if (pageURL && pageURL !== canonicalURL) {
    fields.externalURL = { value: pageURL };
  }
  if (title) {
    fields.title = { value: title };
  }
  return { recordType: "Article", recordName: articleRecordName(id), fields };
}

// Operations for a page that isn't saved yet. A status record left over from an
// earlier delete is updated rather than created, so the create can't collide with it.
export function saveOperations({ id, canonicalURL, pageURL, title, existingStatus }) {
  return [
    { operationType: existingStatus ? "update" : "create", record: statusRecord(id, existingStatus) },
    { operationType: "create", record: pendingArticleRecord(id, canonicalURL, pageURL, title) }
  ];
}

// Saving a page that is already saved moves it back to the inbox, as in the apps.
export function moveToInboxOperation(existingStatus) {
  return {
    operationType: "update",
    record: {
      recordType: "ArticleStatus",
      recordName: existingStatus.recordName,
      recordChangeTag: existingStatus.recordChangeTag,
      fields: { read: { value: "0" } }
    }
  };
}
