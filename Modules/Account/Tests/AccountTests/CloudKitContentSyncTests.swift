//
//  CloudKitContentSyncTests.swift
//  AccountTests
//
//  In a reading list every article's content must reach iCloud and stay there.
//  These tests pin the rules that decide which CloudKit records a batch of
//  status changes turns into, and when a record from iCloud replaces a body.
//

import Foundation
import CloudKit
import Testing
import Articles
import SyncDatabase
@testable import Account

@MainActor struct CloudKitContentSyncTests {

	private let accountManager = TestAccountManager()

	@Test func loneFirstUploadIsNew() throws {
		let update = try #require(statusUpdate([.new]))
		#expect(update.record == .new)
	}

	@Test func firstUploadWithStatusChangeUploadsContent() throws {
		// Saved, then archived before the first send: the content must still go up.
		let update = try #require(statusUpdate([.new, .read], read: true))
		#expect(update.record == .all)
	}

	@Test func changedContentIsUploadedAsModification() throws {
		// A body extracted after the first upload must overwrite the server copy.
		let update = try #require(statusUpdate([.content]))
		#expect(update.record == .all)
	}

	@Test func statusChangeAloneLeavesContentAlone() throws {
		for starred in [false, true] {
			let update = try #require(statusUpdate([.read], read: true, starred: starred))
			#expect(update.record == .statusOnly)
		}
	}

	@Test func deleteWins() throws {
		let update = try #require(statusUpdate([.content, .deleted]))
		#expect(update.record == .delete)
	}

	@Test func contentUpdateWithoutArticleIsDropped() {
		#expect(CloudKitArticleStatusUpdate(articleID: "a", statuses: [syncStatus(.content)], article: nil) == nil)
	}

	@Test func planNeverDeletesContentForStatusChanges() throws {
		let updates = try [
			#require(statusUpdate([.read], articleID: "read", read: true)),
			#require(statusUpdate([.starred], articleID: "starred", starred: true)),
			#require(statusUpdate([.content], articleID: "content")),
			#require(statusUpdate([.new], articleID: "new")),
			#require(statusUpdate([.deleted], articleID: "deleted"))
		]

		let plan = CloudKitArticlesZone.ArticleRecordPlan(updates)

		#expect(plan.deletedArticleIDs == ["deleted"])
		#expect(Set(plan.statusUpdates.map(\.articleID)) == ["read", "starred", "content"])
		#expect(plan.contentUpdates.map(\.articleID) == ["content"])
		#expect(plan.newUpdates.map(\.articleID) == ["new"])
	}

	@Test func firstUploadFindingACopyWithoutABodyUploadsTheBody() throws {
		let updates = try [
			#require(statusUpdate([.new], articleID: "pendingThere")),
			#require(statusUpdate([.new], articleID: "copyNotSent")),
			#require(statusUpdate([.new], articleID: "extractedThere")),
			#require(statusUpdate([.new], articleID: "pendingEverywhere", contentHTML: nil)),
			#require(statusUpdate([.new], articleID: "saved"))
		]

		// Save-if-new found all but the last already in iCloud, and left them as they are there.
		typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
		let zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		var existing = [CKRecord.ID: CKError]()
		let serverBodies: [(articleID: String, contentHTMLData: Data?)] = [("pendingThere", nil), ("extractedThere", Data("body".utf8)), ("pendingEverywhere", nil)]
		for (articleID, contentHTMLData) in serverBodies {
			let recordID = CKRecord.ID(recordName: "a|\(articleID)", zoneID: zoneID)
			let serverRecord = CKRecord(recordType: CloudKitArticlesZone.CloudKitArticle.recordType, recordID: recordID)
			serverRecord[Fields.contentHTMLData] = contentHTMLData
			existing[recordID] = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])
		}
		existing[CKRecord.ID(recordName: "a|copyNotSent", zoneID: zoneID)] = CKError(.serverRecordChanged)
		existing[CKRecord.ID(recordName: "s|saved", zoneID: zoneID)] = CKError(.serverRecordChanged)

		// This device's body replaces a copy without one, or it never reaches iCloud. A copy with
		// a body stays, and a page with no body anywhere uploads nothing.
		let plan = CloudKitArticlesZone.ArticleRecordPlan(updates)
		#expect(plan.contentUploads(forExisting: existing) == ["pendingThere", "copyNotSent"])
	}

	@Test func recordWithoutContentKeepsABodyNotYetUploaded() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		// This device saved three pages with bodies. Two haven't reached iCloud yet: a first
		// upload and a content upload are queued. The third went up long ago.
		let content = ReadingListContent(title: "Title", contentHTML: "<p>Body</p>", summary: "Excerpt", imageURL: "https://example.com/lead.jpg", byline: "Byline")
		let firstUpload = try await account.saveArticle(url: "https://example.com/first?utm_source=x", title: nil, content: content)
		let contentUpload = try await account.saveArticle(url: "https://example.com/content?utm_source=x", title: nil, content: content)
		let uploaded = try await account.saveArticle(url: "https://example.com/uploaded?utm_source=x", title: nil, content: content)
		let syncDatabase = SyncDatabase(databasePath: ":memory:")
		await syncDatabase.insertStatuses([
			SyncStatus(articleID: firstUpload.articleID, key: .new, flag: true),
			SyncStatus(articleID: contentUpload.articleID, key: .content, flag: true)
		])

		// iCloud sends all three without a body or a title. For the first two that's a pending
		// save the browser extension made before this device's body got there; for the third,
		// a fresh save after a delete this device missed.
		typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
		let records = [firstUpload, contentUpload, uploaded].map { article in
			let record = CKRecord(recordType: CloudKitArticlesZone.CloudKitArticle.recordType)
			record[Fields.feedURL] = article.feedID
			record[Fields.uniqueID] = article.uniqueID
			record[Fields.url] = article.uniqueID
			return record
		}
		let zoneDelegate = CloudKitArticlesZoneDelegate(account: account, database: syncDatabase, syncErrorHandler: nil)
		try await zoneDelegate.cloudKitDidModify(changed: records, deleted: [])

		account.emptyCaches()
		let articles = await account.fetchArticlesAsync(.articleIDs([firstUpload.articleID, contentUpload.articleID, uploaded.articleID]))
		#expect(articles.count == 3)
		for kept in articles where kept.articleID != uploaded.articleID {
			#expect(kept.contentHTML == "<p>Body</p>")
			#expect(kept.summary == "Excerpt")
			#expect(kept.rawImageLink == "https://example.com/lead.jpg")
			#expect(kept.authors?.map(\.name) == ["Byline"])
			#expect(kept.title == "Title")
			#expect(kept.rawExternalLink?.hasSuffix("?utm_source=x") == true)
		}
		// With nothing of its own still to upload, the record wins and the page starts fresh.
		let fresh = try #require(articles.first { $0.articleID == uploaded.articleID })
		#expect(fresh.contentHTML == nil)
		#expect(fresh.title == nil)
		#expect(await account.pendingExtractionArticleIDs() == [uploaded.articleID])
	}
}

private extension CloudKitContentSyncTests {

	func statusUpdate(_ keys: [SyncStatus.Key], articleID: String = "a", read: Bool = false, starred: Bool = false, contentHTML: String? = "<p>Body</p>") -> CloudKitArticleStatusUpdate? {
		let statuses = keys.map { syncStatus($0, articleID: articleID) }
		return CloudKitArticleStatusUpdate(articleID: articleID, statuses: statuses, article: article(articleID: articleID, read: read, starred: starred, contentHTML: contentHTML))
	}

	func syncStatus(_ key: SyncStatus.Key, articleID: String = "a") -> SyncStatus {
		SyncStatus(articleID: articleID, key: key, flag: true)
	}

	func article(articleID: String, read: Bool, starred: Bool, contentHTML: String?) -> Article {
		let status = ArticleStatus(articleID: articleID, read: read, starred: starred, dateArrived: Date())
		return Article(accountID: "test", articleID: articleID, feedID: "netnewslist://reading-list", uniqueID: articleID, title: "Title", contentHTML: contentHTML, contentText: nil, markdown: nil, url: "https://example.com/\(articleID)", externalURL: nil, summary: nil, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil, status: status)
	}
}
