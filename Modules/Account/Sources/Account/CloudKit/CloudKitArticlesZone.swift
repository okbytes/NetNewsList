//
//  CloudKitArticlesZone.swift
//  Account
//
//  Created by Maurice Parker on 4/1/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os
import RSParser
import CloudKit
import Articles
import ActivityLog
import SyncDatabase
import CloudKitSync

final class CloudKitArticlesZone: CloudKitZone {

	nonisolated private static let logger = cloudKitLogger
	private static let jsonEncoder = JSONEncoder()

	/// CloudKit caps a record at 1 MB, not counting assets. Compressed content larger
	/// than this goes into a CKAsset instead of an inline field.
	nonisolated private static let maxInlineContentBytes = 700_000

	var zoneID: CKRecordZone.ID

	weak var container: CKContainer?
	weak var database: CKDatabase?
	var delegate: CloudKitZoneDelegate?
	var fetchChangesPageHandler: CloudKitZoneFetchPageHandler?

	struct CloudKitArticle: Sendable {
		static let recordType = "Article"
		struct Fields {
			static let articleStatus = "articleStatus"
			static let feedURL = "webFeedURL"
			static let uniqueID = "uniqueID"
			static let title = "title"
			static let contentHTML = "contentHTML"
			static let contentHTMLData = "contentHTMLData"
			static let contentHTMLAsset = "contentHTMLAsset"
			static let contentText = "contentText"
			static let contentTextData = "contentTextData"
			static let contentTextAsset = "contentTextAsset"
			static let url = "url"
			static let externalURL = "externalURL"
			static let summary = "summary"
			static let imageURL = "imageURL"
			static let datePublished = "datePublished"
			static let dateModified = "dateModified"
			static let parsedAuthors = "parsedAuthors"
		}
	}

	struct CloudKitArticleStatus: Sendable {
		static let recordType = "ArticleStatus"
		struct Fields {
			static let feedExternalID = "webFeedExternalID"
			static let read = "read"
			static let starred = "starred"
		}
	}

	init(container: CKContainer) {
		self.container = container
		self.database = container.privateCloudDatabase
		self.zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
	}

	/// Fetches article-status changes for the zone and returns the cumulative
	/// changed/deleted record counts across every page of the fetch.
	@discardableResult
	@MainActor func refreshArticles() async throws -> (changed: Int, deleted: Int) {
		let articlesDelegate = self.delegate as? CloudKitArticlesZoneDelegate
		articlesDelegate?.resetAccumulation()
		do {
			try await fetchChangesInZone()
		} catch {
			if case CloudKitZoneError.userDeletedZone = error {
				try await createZoneRecord()
				return try await refreshArticles()
			}
			throw error
		}
		return (
			changed: articlesDelegate?.accumulatedChangedCount ?? 0,
			deleted: articlesDelegate?.accumulatedDeletedCount ?? 0
		)
	}

	@MainActor func saveNewArticles(_ articles: Set<Article>) async throws {
		guard !articles.isEmpty else {
			return
		}

		// Every saved article keeps its content in iCloud, read or not, starred or not.
		var records = [CKRecord]()
		for article in articles {
			records.append(makeStatusRecord(article))
			records.append(makeArticleRecord(article))
		}

		await Task.detached(priority: .userInitiated) {
			self.compressArticleRecords(records)
		}.value
		try await save(records)
	}

	func deleteArticles(_ feedExternalID: String, owner: ActivityOwner) async throws {
		let predicate = NSPredicate(format: "webFeedExternalID = %@", feedExternalID)
		let ckQuery = CKQuery(recordType: CloudKitArticleStatus.recordType, predicate: predicate)
		try await delete(ckQuery: ckQuery) { pageRecords in
			logCloudKitSubActivity(owner: owner, kind: .removeFeed, message: "\(pageRecords.count) records")
		}
	}

	/// The records one batch of status updates turns into. Kept pure so the rules that
	/// protect article content can be tested without CloudKit.
	struct ArticleRecordPlan {
		/// Status records saved with `modify` (last writer wins).
		var statusUpdates = [CloudKitArticleStatusUpdate]()
		/// Content records saved with `modify`, overwriting the server copy.
		var contentUpdates = [CloudKitArticleStatusUpdate]()
		/// First uploads: status and content, saved only if they don’t exist yet.
		var newUpdates = [CloudKitArticleStatusUpdate]()
		/// Articles whose status record is deleted. The content record goes with it
		/// through its `.deleteSelf` reference. Nothing else ever deletes content.
		var deletedArticleIDs = [String]()

		init(_ updates: [CloudKitArticleStatusUpdate]) {
			for update in updates {
				switch update.record {
				case .all:
					statusUpdates.append(update)
					contentUpdates.append(update)
				case .new:
					newUpdates.append(update)
				case .delete:
					deletedArticleIDs.append(update.articleID)
				case .statusOnly:
					statusUpdates.append(update)
				}
			}
		}
	}

	struct ModifyArticlesResult {
		var contentUploadCount = 0
		/// Articles whose content upload failed. The caller queues them again.
		var failedContentArticleIDs = Set<String>()
		var contentError: Error?
	}

	@MainActor func modifyArticles(_ statusUpdates: [CloudKitArticleStatusUpdate]) async throws -> ModifyArticlesResult {
		guard !statusUpdates.isEmpty else {
			return ModifyArticlesResult()
		}

		let plan = ArticleRecordPlan(statusUpdates)
		let statusRecords = plan.statusUpdates.map { makeStatusRecord($0) }
		var newRecords = [CKRecord]()
		for update in plan.newUpdates {
			guard let article = update.article else {
				continue
			}
			newRecords.append(makeStatusRecord(update))
			newRecords.append(makeArticleRecord(article))
		}
		let articleRecords = plan.contentUpdates.compactMap { update in
			update.article.map { makeArticleRecord($0) }
		}
		let deleteRecordIDs = plan.deletedArticleIDs.map { CKRecord.ID(recordName: statusID($0), zoneID: zoneID) }

		await Task.detached(priority: .userInitiated) {
			self.compressArticleRecords(articleRecords)
			self.compressArticleRecords(newRecords)
		}.value

		// Statuses go first, and on their own. They're what sync correctness depends on, and
		// `modify` is atomic, so batching them with content records means one article too big
		// to store rejects every status in the request. Sending them first is also the right
		// order: an article record references its status record.
		do {
			try await modify(recordsToSave: statusRecords, recordIDsToDelete: deleteRecordIDs)
			try await saveIfNew(newRecords)
		} catch {
			return try await handleModifyArticlesError(error, statusUpdates: statusUpdates)
		}

		var result = ModifyArticlesResult(contentUploadCount: plan.newUpdates.count)

		// A content failure leaves the statuses sent and is reported back, so the
		// caller can retry the content alone on the next send.
		if !articleRecords.isEmpty {
			do {
				try await modify(recordsToSave: articleRecords, recordIDsToDelete: [])
				result.contentUploadCount += articleRecords.count
			} catch {
				Self.logger.error("CloudKitArticlesZone: modifyArticles content upload failed: \(error.localizedDescription)")
				result.failedContentArticleIDs = Set(plan.contentUpdates.map(\.articleID))
				result.contentError = error
			}
		}

		return result
	}
}

private extension CloudKitArticlesZone {

	func handleModifyArticlesError(_ error: Error, statusUpdates: [CloudKitArticleStatusUpdate]) async throws -> ModifyArticlesResult {
		if case CloudKitZoneError.userDeletedZone = error {
			try await createZoneRecord()
			return try await modifyArticles(statusUpdates)
		}
		throw error
	}

	func statusID(_ id: String) -> String {
		return "s|\(id)"
	}

	func articleID(_ id: String) -> String {
		return "a|\(id)"
	}

	@MainActor func makeStatusRecord(_ article: Article) -> CKRecord {
		let recordID = CKRecord.ID(recordName: statusID(article.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitArticleStatus.recordType, recordID: recordID)
		if let feedExternalID = article.feed?.externalID {
			record[CloudKitArticleStatus.Fields.feedExternalID] = feedExternalID
		}
		record[CloudKitArticleStatus.Fields.read] = article.status.read ? "1" : "0"
		record[CloudKitArticleStatus.Fields.starred] = article.status.starred ? "1" : "0"
		return record
	}

	@MainActor func makeStatusRecord(_ statusUpdate: CloudKitArticleStatusUpdate) -> CKRecord {
		let recordID = CKRecord.ID(recordName: statusID(statusUpdate.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitArticleStatus.recordType, recordID: recordID)

		if let feedExternalID = statusUpdate.article?.feed?.externalID {
			record[CloudKitArticleStatus.Fields.feedExternalID] = feedExternalID
		}

		record[CloudKitArticleStatus.Fields.read] = statusUpdate.isRead ? "1" : "0"
		record[CloudKitArticleStatus.Fields.starred] = statusUpdate.isStarred ? "1" : "0"

		return record
	}

	@MainActor func makeArticleRecord(_ article: Article) -> CKRecord {
		let recordID = CKRecord.ID(recordName: articleID(article.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitArticle.recordType, recordID: recordID)

		let articleStatusRecordID = CKRecord.ID(recordName: statusID(article.articleID), zoneID: zoneID)
		record[CloudKitArticle.Fields.articleStatus] = CKRecord.Reference(recordID: articleStatusRecordID, action: .deleteSelf)
		record[CloudKitArticle.Fields.feedURL] = article.feed?.url
		record[CloudKitArticle.Fields.uniqueID] = article.uniqueID
		record[CloudKitArticle.Fields.title] = article.title
		record[CloudKitArticle.Fields.contentHTML] = article.contentHTML
		record[CloudKitArticle.Fields.contentText] = article.contentText
		record[CloudKitArticle.Fields.url] = article.rawLink
		record[CloudKitArticle.Fields.externalURL] = article.rawExternalLink
		record[CloudKitArticle.Fields.summary] = article.summary
		record[CloudKitArticle.Fields.imageURL] = article.rawImageLink
		record[CloudKitArticle.Fields.datePublished] = article.datePublished
		record[CloudKitArticle.Fields.dateModified] = article.dateModified

		if let authors = article.authors, !authors.isEmpty {
			var parsedAuthors = [String]()
			for author in authors {
				let parsedAuthor = ParsedAuthor(name: author.name,
												url: author.url,
												avatarURL: author.avatarURL,
												emailAddress: author.emailAddress)
				if let data = try? Self.jsonEncoder.encode(parsedAuthor), let encodedParsedAuthor = String(data: data, encoding: .utf8) {
					parsedAuthors.append(encodedParsedAuthor)
				}
			}
			record[CloudKitArticle.Fields.parsedAuthors] = parsedAuthors
		}

		return record
	}

	nonisolated func compressArticleRecords(_ records: [CKRecord]) {
		for record in records where record.recordType == CloudKitArticle.recordType {
			moveCompressedContent(in: record, stringField: CloudKitArticle.Fields.contentHTML, dataField: CloudKitArticle.Fields.contentHTMLData, assetField: CloudKitArticle.Fields.contentHTMLAsset)
			moveCompressedContent(in: record, stringField: CloudKitArticle.Fields.contentText, dataField: CloudKitArticle.Fields.contentTextData, assetField: CloudKitArticle.Fields.contentTextAsset)
		}
	}

	/// Replaces a string field with LZFSE-compressed data: inline when it fits, otherwise as a
	/// CKAsset, so a long article never makes its record exceed CloudKit’s 1 MB limit.
	/// Both destination fields are always set, so a stale value from an earlier save is cleared.
	nonisolated func moveCompressedContent(in record: CKRecord, stringField: String, dataField: String, assetField: String) {
		guard let string = record[stringField] as? String,
			  let compressed = try? (Data(string.utf8) as NSData).compressed(using: .lzfse) as Data else {
			return
		}

		if compressed.count <= Self.maxInlineContentBytes {
			record[dataField] = compressed
			record[assetField] = nil
			record[stringField] = nil
			return
		}

		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CloudKitArticleAssets", isDirectory: true)
		let fileName = "\(record.recordID.recordName)-\(assetField).lzfse".replacingOccurrences(of: "/", with: "_")
		let fileURL = folder.appendingPathComponent(fileName)
		do {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try compressed.write(to: fileURL, options: .atomic)
		} catch {
			Self.logger.error("CloudKitArticlesZone: could not write content asset for \(record.recordID.recordName, privacy: .public): \(error.localizedDescription)")
			return
		}
		record[assetField] = CKAsset(fileURL: fileURL)
		record[dataField] = nil
		record[stringField] = nil
	}
}
