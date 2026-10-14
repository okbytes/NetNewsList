//
//  CloudKitArticlesZone.swift
//  Account
//
//  Created by Maurice Parker on 4/1/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os
import RSCore
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
	let webDatabase: CloudKitWebDatabase?
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
		self.webDatabase = nil
		self.zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
	}

	/// The zone over CloudKit Web Services (`CloudKitWebSync`).
	init(webDatabase: CloudKitWebDatabase) {
		self.webDatabase = webDatabase
		self.zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
	}

	/// Status records are `s|<articleID>`, article records `a|<articleID>`.
	func webRecordType(forDeletedRecordName recordName: String) -> CKRecord.RecordType? {
		if recordName.hasPrefix("s|") {
			return CloudKitArticleStatus.recordType
		}
		if recordName.hasPrefix("a|") {
			return CloudKitArticle.recordType
		}
		return nil
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

		/// First uploads that found the article already in iCloud. `serverCopies` are iCloud’s copies
		/// of them, merged into the articles here (`CloudKitArticlesZoneDelegate.mergeICloudCopies`)
		/// so a later upload from here doesn’t erase what only iCloud’s copy has (the browser
		/// extension’s title and saved date). `articleIDs` are those whose copy has no body while
		/// this device has one: that copy is a pending save made elsewhere (the browser extension,
		/// another device), save-if-new leaves it as it is, so this device’s body goes up as a
		/// content upload, which overwrites it. When CloudKit doesn’t send its copy, the body goes
		/// up all the same. The content upload also sends this device’s status, unread, which is
		/// what saving a page again does anyway (it moves an archived page back to the Queue).
		///
		/// A copy that has a body stays, so the first body to reach iCloud wins even when the one
		/// here is better: an anonymous extraction made elsewhere that gets there first beats a
		/// later Safari or Shortcut capture made here. That is deliberate. Reset iCloud Sync sends
		/// every article here as a first upload, and uploading over bodies then would overwrite
		/// newer ones on every device.
		func contentUploads(forUnsaved unsavedRecords: CloudKitUnsavedRecords) -> (articleIDs: Set<String>, serverCopies: [CKRecord]) {
			let unsavedByRecordName = Dictionary(unsavedRecords.map { ($0.key.recordName, $0.value) }, uniquingKeysWith: { first, _ in first })
			var articleIDs = Set<String>()
			var serverCopies = [CKRecord]()
			for update in newUpdates {
				guard let error = unsavedByRecordName[CloudKitArticlesZone.articleRecordName(update.articleID)],
					  error.code == .serverRecordChanged else {
					continue
				}
				let serverCopy = error.serverRecord
				if let serverCopy {
					serverCopies.append(serverCopy)
				}
				if update.article?.contentHTML != nil, !(serverCopy?.hasArticleContent ?? false) {
					articleIDs.insert(update.articleID)
				}
			}
			return (articleIDs, serverCopies)
		}

		/// First uploads iCloud refused (its storage was full, for one): a record of the article
		/// wasn’t saved, and not because iCloud already has it. They’re sent again later.
		func failedFirstUploads(_ unsavedRecords: CloudKitUnsavedRecords) -> Set<String> {
			let refusedRecordNames = Set(unsavedRecords.filter { $0.value.code != .serverRecordChanged }.map(\.key.recordName))
			return Set(newUpdates.map(\.articleID).filter { articleID in
				refusedRecordNames.contains(CloudKitArticlesZone.statusRecordName(articleID)) || refusedRecordNames.contains(CloudKitArticlesZone.articleRecordName(articleID))
			})
		}
	}

	struct ModifyArticlesResult {
		var contentUploadCount = 0
		/// Articles whose content upload failed. The caller queues them again.
		var failedContentArticleIDs = Set<String>()
		var contentError: Error?
		/// First uploads iCloud refused. The caller queues them again.
		var failedFirstUploadArticleIDs = Set<String>()
		var firstUploadError: Error?
		/// First uploads that found a copy without a body in iCloud. The caller queues a content upload.
		var articleIDsNeedingContentUpload = Set<String>()
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
		let deleteRecordIDs = plan.deletedArticleIDs.map { CKRecord.ID(recordName: Self.statusRecordName($0), zoneID: zoneID) }

		await Task.detached(priority: .userInitiated) {
			self.compressArticleRecords(articleRecords)
			self.compressArticleRecords(newRecords)
		}.value

		// Statuses go first, and on their own. They're what sync correctness depends on, and
		// `modify` is atomic, so batching them with content records means one article too big
		// to store rejects every status in the request. Sending them first is also the right
		// order: an article record references its status record.
		let unsavedRecords: CloudKitUnsavedRecords
		do {
			try await modify(recordsToSave: statusRecords, recordIDsToDelete: deleteRecordIDs)
			unsavedRecords = try await saveIfNew(newRecords)
		} catch {
			return try await handleModifyArticlesError(error, statusUpdates: statusUpdates)
		}

		var result = ModifyArticlesResult()
		result.failedFirstUploadArticleIDs = plan.failedFirstUploads(unsavedRecords)
		if !result.failedFirstUploadArticleIDs.isEmpty {
			Self.logger.error("CloudKitArticlesZone: iCloud refused \(result.failedFirstUploadArticleIDs.count, privacy: .public) first uploads; sending them again later")
			result.firstUploadError = unsavedRecords.values.first { $0.code != .serverRecordChanged }
		}
		result.contentUploadCount = plan.newUpdates.count - result.failedFirstUploadArticleIDs.count

		let contentUploads = plan.contentUploads(forUnsaved: unsavedRecords)
		if !contentUploads.articleIDs.isEmpty {
			Self.logger.info("CloudKitArticlesZone: \(contentUploads.articleIDs.count, privacy: .public) first uploads found the article in iCloud without a body; sending the body as content")
			// A content upload writes every field, so iCloud’s copy goes into the article here
			// first. Otherwise the upload would erase a title, address or saved date that only
			// iCloud’s copy has.
			await (delegate as? CloudKitArticlesZoneDelegate)?.mergeICloudCopies(contentUploads.serverCopies)
			result.articleIDsNeedingContentUpload = contentUploads.articleIDs
		}

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

	/// How this device’s proposed saved dates (`Account.savedDateProposals`) meet iCloud’s, so
	/// the earliest wins without a later date overwriting it: a pure part that can be tested
	/// without CloudKit.
	struct SavedDatePlan {
		/// Dates settled without saving anything: iCloud’s when it isn’t more than a minute later
		/// than the proposal, and the proposal for an article iCloud doesn’t have (not uploaded
		/// yet, or deleted; its first upload, if any, carries the date).
		private(set) var settledWithoutSaving = [String: Date]()
		/// iCloud’s records with the proposed date, to be saved only if nothing changed them since
		/// they were fetched.
		private(set) var recordsToSave = [CKRecord]()
		private var proposedDates = [String: Date]()

		/// `fetchedRecords` holds iCloud’s Article records by article ID, `missingArticleIDs` the
		/// articles iCloud has no record of. An article in neither (its fetch failed) isn’t settled.
		init(proposals: [String: Date], fetchedRecords: [String: CKRecord], missingArticleIDs: Set<String>) {
			for (articleID, proposedDate) in proposals {
				if missingArticleIDs.contains(articleID) {
					settledWithoutSaving[articleID] = proposedDate
					continue
				}
				guard let record = fetchedRecords[articleID] else {
					continue
				}
				if let iCloudDate = record[CloudKitArticle.Fields.datePublished] as? Date, iCloudDate.timeIntervalSince(proposedDate) <= Account.savedDateTolerance {
					settledWithoutSaving[articleID] = iCloudDate
					continue
				}
				record[CloudKitArticle.Fields.datePublished] = proposedDate
				recordsToSave.append(record)
				proposedDates[articleID] = proposedDate
			}
		}

		/// Every settled date once the records are saved. A record iCloud didn’t save (another
		/// device changed it meanwhile) stays as it is; the next launch tries again with what
		/// that change brings here.
		func settledDates(unsaved: CloudKitUnsavedRecords) -> [String: Date] {
			let unsavedRecordNames = Set(unsaved.keys.map(\.recordName))
			var dates = settledWithoutSaving
			for (articleID, date) in proposedDates where !unsavedRecordNames.contains(CloudKitArticlesZone.articleRecordName(articleID)) {
				dates[articleID] = date
			}
			return dates
		}
	}

	/// Settles this device’s proposed saved dates with iCloud (`SavedDatePlan`) and returns the
	/// dates to store here. Only the `datePublished` of iCloud’s records is read and written.
	@MainActor func settleSavedDates(_ proposals: [String: Date]) async throws -> [String: Date] {
		guard !proposals.isEmpty, database != nil || webDatabase != nil else {
			return [String: Date]()
		}
		var fetchedRecords = [String: CKRecord]()
		var missingArticleIDs = Set<String>()
		for chunk in Array(proposals.keys).chunked(into: 200) {
			let recordIDs = chunk.map { CKRecord.ID(recordName: Self.articleRecordName($0), zoneID: zoneID) }
			let results = try await records(for: recordIDs, desiredKeys: [CloudKitArticle.Fields.datePublished])
			for (articleID, recordID) in zip(chunk, recordIDs) {
				switch results[recordID] {
				case .success(let record):
					fetchedRecords[articleID] = record
				case .failure(let error as CKError) where error.code == .unknownItem:
					missingArticleIDs.insert(articleID)
				case .failure(let error):
					Self.logger.error("CloudKitArticlesZone: couldn’t read the saved date of \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
				case nil:
					break
				}
			}
		}

		let plan = SavedDatePlan(proposals: proposals, fetchedRecords: fetchedRecords, missingArticleIDs: missingArticleIDs)
		var unsaved = CloudKitUnsavedRecords()
		if !plan.recordsToSave.isEmpty {
			// Save-if-new saves a fetched record only if iCloud’s copy is unchanged since the fetch.
			unsaved = try await saveIfNew(plan.recordsToSave)
		}
		let settledDates = plan.settledDates(unsaved: unsaved)
		Self.logger.info("CloudKitArticlesZone: settled \(settledDates.count, privacy: .public) of \(proposals.count, privacy: .public) proposed saved dates, \(plan.recordsToSave.count - unsaved.count, privacy: .public) of them in iCloud")
		return settledDates
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

	nonisolated static func statusRecordName(_ articleID: String) -> String {
		return "s|\(articleID)"
	}

	nonisolated static func articleRecordName(_ articleID: String) -> String {
		return "a|\(articleID)"
	}

	@MainActor func makeStatusRecord(_ article: Article) -> CKRecord {
		let recordID = CKRecord.ID(recordName: Self.statusRecordName(article.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitArticleStatus.recordType, recordID: recordID)
		if let feedExternalID = article.feed?.externalID {
			record[CloudKitArticleStatus.Fields.feedExternalID] = feedExternalID
		}
		record[CloudKitArticleStatus.Fields.read] = article.status.read ? "1" : "0"
		record[CloudKitArticleStatus.Fields.starred] = article.status.starred ? "1" : "0"
		return record
	}

	@MainActor func makeStatusRecord(_ statusUpdate: CloudKitArticleStatusUpdate) -> CKRecord {
		let recordID = CKRecord.ID(recordName: Self.statusRecordName(statusUpdate.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitArticleStatus.recordType, recordID: recordID)

		if let feedExternalID = statusUpdate.article?.feed?.externalID {
			record[CloudKitArticleStatus.Fields.feedExternalID] = feedExternalID
		}

		record[CloudKitArticleStatus.Fields.read] = statusUpdate.isRead ? "1" : "0"
		record[CloudKitArticleStatus.Fields.starred] = statusUpdate.isStarred ? "1" : "0"

		return record
	}

	@MainActor func makeArticleRecord(_ article: Article) -> CKRecord {
		let recordID = CKRecord.ID(recordName: Self.articleRecordName(article.articleID), zoneID: zoneID)
		let record = CKRecord(recordType: CloudKitArticle.recordType, recordID: recordID)

		let articleStatusRecordID = CKRecord.ID(recordName: Self.statusRecordName(article.articleID), zoneID: zoneID)
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
		// A missing date is left out rather than sent as nil, which would erase iCloud’s:
		// `datePublished` is the date saved, and a device that hasn’t received it yet
		// mustn’t remove it everywhere when it uploads a body.
		if let datePublished = article.datePublished {
			record[CloudKitArticle.Fields.datePublished] = datePublished
		}
		if let dateModified = article.dateModified {
			record[CloudKitArticle.Fields.dateModified] = dateModified
		}

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

private extension CKRecord {

	/// Whether this Article record has a body, in any of the forms `makeParsedItem` reads.
	var hasArticleContent: Bool {
		typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
		return self[Fields.contentHTMLData] != nil || self[Fields.contentHTMLAsset] != nil || self[Fields.contentHTML] != nil
	}
}
