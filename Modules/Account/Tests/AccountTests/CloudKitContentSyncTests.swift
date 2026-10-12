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

	@Test func firstUploadsICloudDidNotSaveAreFollowedUp() throws {
		let updates = try [
			#require(statusUpdate([.new], articleID: "pendingThere")),
			#require(statusUpdate([.new], articleID: "copyNotSent")),
			#require(statusUpdate([.new], articleID: "extractedThere")),
			#require(statusUpdate([.new], articleID: "pendingEverywhere", contentHTML: nil)),
			#require(statusUpdate([.new], articleID: "storageFull")),
			#require(statusUpdate([.new], articleID: "articleRefused")),
			#require(statusUpdate([.new], articleID: "saved"))
		]

		// Save-if-new found the first four already in iCloud, and left them as they are there.
		typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
		let zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		var unsaved = [CKRecord.ID: CKError]()
		let serverBodies: [(articleID: String, contentHTMLData: Data?)] = [("pendingThere", nil), ("extractedThere", Data("body".utf8)), ("pendingEverywhere", nil)]
		for (articleID, contentHTMLData) in serverBodies {
			let recordID = CKRecord.ID(recordName: "a|\(articleID)", zoneID: zoneID)
			let serverRecord = CKRecord(recordType: CloudKitArticlesZone.CloudKitArticle.recordType, recordID: recordID)
			serverRecord[Fields.contentHTMLData] = contentHTMLData
			unsaved[recordID] = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])
		}
		unsaved[CKRecord.ID(recordName: "a|copyNotSent", zoneID: zoneID)] = CKError(.serverRecordChanged)
		unsaved[CKRecord.ID(recordName: "s|saved", zoneID: zoneID)] = CKError(.serverRecordChanged)

		// It refused the next two: iCloud storage is full, or it turned away the Article record alone.
		unsaved[CKRecord.ID(recordName: "s|storageFull", zoneID: zoneID)] = CKError(.quotaExceeded)
		unsaved[CKRecord.ID(recordName: "a|storageFull", zoneID: zoneID)] = CKError(.quotaExceeded)
		unsaved[CKRecord.ID(recordName: "a|articleRefused", zoneID: zoneID)] = CKError(.requestRateLimited)

		// This device's body replaces a copy without one, after that copy is merged in here, or it
		// never reaches iCloud. A copy with a body stays, and a page with no body anywhere uploads nothing.
		let plan = CloudKitArticlesZone.ArticleRecordPlan(updates)
		let contentUploads = plan.contentUploads(forUnsaved: unsaved)
		#expect(contentUploads.articleIDs == ["pendingThere", "copyNotSent"])
		#expect(contentUploads.serverCopies.map(\.recordID.recordName) == ["a|pendingThere"])

		// A refused first upload goes again later, or the page never leaves this device. One that
		// found its records in iCloud is done.
		#expect(plan.failedFirstUploads(unsaved) == ["storageFull", "articleRefused"])
	}

	@Test func contentUploadAfterARejectedFirstUploadKeepsICloudsTitleAddressAndDate() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		// A Shortcut saved a page here with a body but no title, before this device saw the
		// browser extension's save of the same page in iCloud.
		let content = ReadingListContent(contentHTML: "<p>Body</p>", summary: "Excerpt", imageURL: "https://example.com/lead.jpg", byline: "Byline")
		let saved = try await account.saveArticle(url: "https://example.com/page", title: nil, content: content)

		// The extension's copy has the tab's title, the address as saved and the time it was
		// saved, and no body. Save-if-new left it as it is.
		typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
		let zoneID = CKRecordZone.ID(zoneName: "Articles", ownerName: CKCurrentUserDefaultName)
		let iCloudCopy = CKRecord(recordType: CloudKitArticlesZone.CloudKitArticle.recordType, recordID: CKRecord.ID(recordName: "a|\(saved.articleID)", zoneID: zoneID))
		iCloudCopy[Fields.feedURL] = saved.feedID
		iCloudCopy[Fields.uniqueID] = saved.uniqueID
		iCloudCopy[Fields.url] = saved.uniqueID
		iCloudCopy[Fields.externalURL] = "https://example.com/page?utm_source=x"
		iCloudCopy[Fields.title] = "Tab Title"
		let dateSaved = Date(timeIntervalSince1970: 1_790_000_000)
		iCloudCopy[Fields.datePublished] = dateSaved
		let unsaved = [iCloudCopy.recordID: CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: iCloudCopy])]

		let firstUpload = try #require(CloudKitArticleStatusUpdate(articleID: saved.articleID, statuses: [syncStatus(.new, articleID: saved.articleID)], article: saved))
		let contentUploads = CloudKitArticlesZone.ArticleRecordPlan([firstUpload]).contentUploads(forUnsaved: unsaved)
		#expect(contentUploads.articleIDs == [saved.articleID])
		let zoneDelegate = CloudKitArticlesZoneDelegate(account: account, database: SyncDatabase(databasePath: ":memory:"), syncErrorHandler: nil)
		await zoneDelegate.mergeICloudCopies(contentUploads.serverCopies)

		// The content upload sends the article here and writes every field, so it must carry
		// iCloud's title, address and date, or they're erased everywhere, along with the body here.
		account.emptyCaches()
		let uploaded = try #require(await account.fetchArticlesAsync(.articleIDs([saved.articleID])).first)
		#expect(uploaded.title == "Tab Title")
		#expect(uploaded.rawExternalLink == "https://example.com/page?utm_source=x")
		#expect(uploaded.datePublished == dateSaved)
		#expect(uploaded.contentHTML == "<p>Body</p>")
		#expect(uploaded.summary == "Excerpt")
		#expect(uploaded.rawImageLink == "https://example.com/lead.jpg")
		#expect(uploaded.authors?.map(\.name) == ["Byline"])
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
