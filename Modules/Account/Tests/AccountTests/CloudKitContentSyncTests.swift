//
//  CloudKitContentSyncTests.swift
//  AccountTests
//
//  In a reading list every article's content must reach iCloud and stay there.
//  These tests pin the rules that decide which CloudKit records a batch of
//  status changes turns into.
//

import Foundation
import Testing
import Articles
import SyncDatabase
@testable import Account

@MainActor struct CloudKitContentSyncTests {

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
}

private extension CloudKitContentSyncTests {

	func statusUpdate(_ keys: [SyncStatus.Key], articleID: String = "a", read: Bool = false, starred: Bool = false) -> CloudKitArticleStatusUpdate? {
		let statuses = keys.map { syncStatus($0, articleID: articleID) }
		return CloudKitArticleStatusUpdate(articleID: articleID, statuses: statuses, article: article(articleID: articleID, read: read, starred: starred))
	}

	func syncStatus(_ key: SyncStatus.Key, articleID: String = "a") -> SyncStatus {
		SyncStatus(articleID: articleID, key: key, flag: true)
	}

	func article(articleID: String, read: Bool, starred: Bool) -> Article {
		let status = ArticleStatus(articleID: articleID, read: read, starred: starred, dateArrived: Date())
		return Article(accountID: "test", articleID: articleID, feedID: "netnewslist://reading-list", uniqueID: articleID, title: "Title", contentHTML: "<p>Body</p>", contentText: nil, markdown: nil, url: "https://example.com/\(articleID)", externalURL: nil, summary: nil, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil, status: status)
	}
}
