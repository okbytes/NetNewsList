//
//  CloudKitArticlesZoneDelegate.swift
//  Account
//
//  Created by Maurice Parker on 4/1/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os
import RSCore
import RSParser
import RSWeb
import CloudKit
import SyncDatabase
import Articles
import ArticlesDatabase
import CloudKitSync

final class CloudKitArticlesZoneDelegate: CloudKitZoneDelegate {

	private static let logger = cloudKitLogger

	weak var account: Account?
	var syncDatabase: SyncDatabase
	let syncErrorHandler: CloudKitSyncErrorHandler?

	/// Number of records changed in the most recent sync.
	private(set) var lastChangedCount = 0
	/// Number of records deleted in the most recent sync.
	private(set) var lastDeletedCount = 0

	/// Running totals across all pages of the current `refreshArticles` call.
	/// Reset by `resetAccumulation()`; accumulated in `cloudKitDidModify`.
	private(set) var accumulatedChangedCount = 0
	private(set) var accumulatedDeletedCount = 0

	init(account: Account, database: SyncDatabase, syncErrorHandler: CloudKitSyncErrorHandler?) {
		self.account = account
		self.syncDatabase = database
		self.syncErrorHandler = syncErrorHandler
	}

	func resetAccumulation() {
		accumulatedChangedCount = 0
		accumulatedDeletedCount = 0
	}

	func cloudKitDidModify(changed: [CKRecord], deleted: [CloudKitRecordKey]) async throws {
		lastChangedCount = changed.count
		lastDeletedCount = deleted.count
		accumulatedChangedCount += changed.count
		accumulatedDeletedCount += deleted.count

		let pendingReadStatusArticleIDs = (try? await syncDatabase.selectPendingReadStatusArticleIDs()) ?? Set<String>()
		let pendingStarredStatusArticleIDs = (try? await syncDatabase.selectPendingStarredStatusArticleIDs()) ?? Set<String>()
		let pendingFirstUploadArticleIDs = (try? await syncDatabase.selectPendingFirstUploadArticleIDs()) ?? Set<String>()

		await delete(recordKeys: deleted, keeping: pendingStarredStatusArticleIDs.union(pendingFirstUploadArticleIDs))
		await update(records: changed,
					 pendingReadStatusArticleIDs: pendingReadStatusArticleIDs,
					 pendingStarredStatusArticleIDs: pendingStarredStatusArticleIDs)
	}

	/// Merges iCloud’s copies of articles whose first upload found them already in iCloud
	/// (`ArticleRecordPlan.contentUploads`) into the articles here. This device saved the page
	/// before it saw iCloud’s copy, so the article here can lack what the copy has: the browser
	/// extension writes the tab’s title and the time the page was saved, and a Shortcut can send a
	/// body without a title. Any later upload from here (this device’s body, or its extraction)
	/// writes every field, and would otherwise erase them. A body here, and the excerpt, lead
	/// image and byline extracted with it, is kept when the copy has none; a title, address or
	/// date in iCloud’s copy replaces the one here, as when the copy arrives in a fetch. Only
	/// articles still stored here are updated, in the same transaction, so an article deleted
	/// while its first upload was under way isn’t brought back.
	func mergeICloudCopies(_ records: [CKRecord]) async {
		let parsedItems = records.compactMap { makeParsedItem($0) }
		for (feedID, items) in Dictionary(grouping: parsedItems, by: \.feedURL) {
			let articleIDs = Set(items.map { Article.calculatedArticleID(feedID: feedID, uniqueID: $0.uniqueID) })
			_ = await account?.updateAsync(feedID: feedID, parsedItems: Set(items), keepingContentOf: articleIDs, updatingStoredOnly: true)
		}
	}
}

private extension CloudKitArticlesZoneDelegate {

	/// Deletes the articles whose status records iCloud deleted, but `keeping` some: a pending star
	/// change, and a page saved here whose first upload hasn’t gone yet. That save is newer than any
	/// deletion this device hasn’t seen: the same page deleted elsewhere earlier (an article’s ID
	/// comes from its address, so saving it again reuses it), which a change fetch from the start
	/// over the web lists along with the zone’s whole history. Its first upload puts it back.
	func delete(recordKeys: [CloudKitRecordKey], keeping keptArticleIDs: Set<String>) async {
		let receivedRecordIDs = recordKeys.filter({ $0.recordType == CloudKitArticlesZone.CloudKitArticleStatus.recordType }).map({ $0.recordID })
		let receivedArticleIDs = Set(receivedRecordIDs.map({ stripPrefix($0.externalID) }))
		let deletableArticleIDs = receivedArticleIDs.subtracting(keptArticleIDs)

		guard !deletableArticleIDs.isEmpty else {
			return
		}

		await syncDatabase.deleteSelectedForProcessing(deletableArticleIDs)
		await account?.delete(articleIDs: deletableArticleIDs)
	}

	func update(records: [CKRecord], pendingReadStatusArticleIDs: Set<String>, pendingStarredStatusArticleIDs: Set<String>) async {

		let receivedUnreadArticleIDs = Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.read] == "0" }).map({ stripPrefix($0.externalID) }))
		let receivedReadArticleIDs =  Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.read] == "1" }).map({ stripPrefix($0.externalID) }))
		let receivedUnstarredArticleIDs =  Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.starred] == "0" }).map({ stripPrefix($0.externalID) }))
		let receivedStarredArticleIDs =  Set(records.filter({ $0[CloudKitArticlesZone.CloudKitArticleStatus.Fields.starred] == "1" }).map({ stripPrefix($0.externalID) }))

		let updateableUnreadArticleIDs = receivedUnreadArticleIDs.subtracting(pendingReadStatusArticleIDs)
		let updateableReadArticleIDs = receivedReadArticleIDs.subtracting(pendingReadStatusArticleIDs)
		let updateableUnstarredArticleIDs = receivedUnstarredArticleIDs.subtracting(pendingStarredStatusArticleIDs)
		let updateableStarredArticleIDs = receivedStarredArticleIDs.subtracting(pendingStarredStatusArticleIDs)

		// Parse items on background thread
		let feedIDsAndItems = await Task.detached(priority: .userInitiated) {
			let parsedItems = records.compactMap { makeParsedItem($0) }
			return Dictionary(grouping: parsedItems, by: { item in item.feedURL }).mapValues { Set($0) }
		}.value

		await self.account?.markAsUnreadAsync(articleIDs: updateableUnreadArticleIDs)
		await self.account?.markAsReadAsync(articleIDs: updateableReadArticleIDs)
		await self.account?.markAsUnstarredAsync(articleIDs: updateableUnstarredArticleIDs)
		await self.account?.markAsStarredAsync(articleIDs: updateableStarredArticleIDs)

		for (feedID, parsedItems) in feedIDsAndItems {
			// A record without a body doesn’t replace one this device hasn’t uploaded yet. That record
			// is a pending save made elsewhere (another device’s save by address) before this
			// device’s body reached iCloud; the queued upload overwrites it. Without an upload queued,
			// the record wins, so a page deleted and saved again elsewhere starts fresh here too.
			// Read here rather than when the fetch began, so a body saved and queued during the
			// fetch is in the set.
			let unsentContentArticleIDs = (try? await syncDatabase.selectPendingContentArticleIDs()) ?? Set<String>()
			guard let articleChanges = await self.account?.updateAsync(feedID: feedID, parsedItems: parsedItems, keepingContentOf: unsentContentArticleIDs) else {
				continue
			}
			guard let deletes = articleChanges.deleted, !deletes.isEmpty else {
				continue
			}
			let syncStatuses = Set(deletes.map { SyncStatus(articleID: $0.articleID, key: .deleted, flag: true) })
			await self.syncDatabase.insertStatuses(syncStatuses)
		}
	}

	func stripPrefix(_ externalID: String) -> String {
		return String(externalID[externalID.index(externalID.startIndex, offsetBy: 2)..<externalID.endIndex])
	}
}

nonisolated func makeParsedItem(_ articleRecord: CKRecord) -> ParsedItem? {
	guard articleRecord.recordType == CloudKitArticlesZone.CloudKitArticle.recordType else {
		return nil
	}

	var parsedAuthors = Set<ParsedAuthor>()

	let decoder = JSONDecoder()

	if let encodedParsedAuthors = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.parsedAuthors] as? [String] {
		for encodedParsedAuthor in encodedParsedAuthors {
			if let data = encodedParsedAuthor.data(using: .utf8), let parsedAuthor = try? decoder.decode(ParsedAuthor.self, from: data) {
				parsedAuthors.insert(parsedAuthor)
			}
		}
	}

	guard let uniqueID = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.uniqueID] as? String,
		  let feedURL = articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.feedURL] as? String else {
		return nil
	}

	typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
	let contentHTML = decompressedString(in: articleRecord, stringField: Fields.contentHTML, dataField: Fields.contentHTMLData, assetField: Fields.contentHTMLAsset)
	let contentText = decompressedString(in: articleRecord, stringField: Fields.contentText, dataField: Fields.contentTextData, assetField: Fields.contentTextAsset)

	let parsedItem = ParsedItem(syncServiceID: nil,
								uniqueID: uniqueID,
								feedURL: feedURL,
								url: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.url] as? String,
								externalURL: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.externalURL] as? String,
								title: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.title] as? String,
								language: nil,
								contentHTML: contentHTML,
								contentText: contentText,
								markdown: nil,
								summary: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.summary] as? String,
								imageURL: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.imageURL] as? String,
								bannerImageURL: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.imageURL] as? String,
								datePublished: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.datePublished] as? Date,
								dateModified: articleRecord[CloudKitArticlesZone.CloudKitArticle.Fields.dateModified] as? Date,
								authors: parsedAuthors,
								tags: nil,
								attachments: nil)

	return parsedItem
}

/// Content arrives as a plain string (old records), inline LZFSE data, or an LZFSE CKAsset for long articles.
nonisolated private func decompressedString(in record: CKRecord, stringField: String, dataField: String, assetField: String) -> String? {
	var compressedData: NSData?
	if let data = record[dataField] as? NSData {
		compressedData = data
	} else if let asset = record[assetField] as? CKAsset, let fileURL = asset.fileURL, let data = try? Data(contentsOf: fileURL) {
		compressedData = data as NSData
	}
	if let compressedData, let decompressed = try? compressedData.decompressed(using: .lzfse) {
		return String(data: decompressed as Data, encoding: .utf8)
	}
	return record[stringField] as? String
}
