//
//  RetentionTests.swift
//  ArticlesDatabase
//
//  A reading list must never lose a saved article on its own. These tests pin the
//  rules that replaced NetNewsWire's feed-based retention: nothing is deleted for being
//  old, for missing from an update, or at startup; old pages arrive unread; and an
//  explicit delete removes the status too, so saving the page again starts fresh.
//

import Foundation
import Testing
import Articles
import RSParser
import ArticlesDatabase

@MainActor @Suite final class RetentionTests {

	private let database: ArticlesDatabase
	private let feedID = "netnewslist://reading-list"

	init() {
		self.database = ArticlesDatabase(databaseFilePath: ":memory:", accountID: "test")
	}

	@Test func updateWithOtherArticlesKeepsEarlierOnes() async {
		_ = await database.updateAsync(parsedItems: [parsedItem("a")], feedID: feedID)
		_ = await database.updateAsync(parsedItems: [parsedItem("b")], feedID: feedID)

		database.emptyCaches()
		let uniqueIDs = Set(await database.fetchArticlesAsync(feedID: feedID).map(\.uniqueID))
		#expect(uniqueIDs == ["a", "b"])
	}

	@Test func startupCleanupKeepsArticles() async {
		_ = await database.updateAsync(parsedItems: [parsedItem("a")], feedID: feedID)

		database.cleanupDatabaseAtStartup()

		database.emptyCaches()
		let articles = await database.fetchArticlesAsync(feedID: feedID)
		#expect(articles.count == 1)
	}

	@Test func oldPageArrivesUnread() async throws {
		let twoYearsAgo = Date(timeIntervalSinceNow: -2 * 365 * 24 * 60 * 60)
		let changes = await database.updateAsync(parsedItems: [parsedItem("old", datePublished: twoYearsAgo)], feedID: feedID)

		let article = try #require(changes.new?.first)
		#expect(!article.status.read)
	}

	@Test func deleteRemovesStatusSoResavingStartsFresh() async throws {
		let changes = await database.updateAsync(parsedItems: [parsedItem("a")], feedID: feedID)
		let articleID = try #require(changes.new?.first?.articleID)
		_ = await database.markAsync(articleIDs: [articleID], statusKey: .starred, flag: true)
		_ = await database.markAsync(articleIDs: [articleID], statusKey: .read, flag: true)

		await database.deleteAsync(articleIDs: [articleID])
		database.emptyCaches()
		#expect(await database.fetchArticlesAsync(feedID: feedID).isEmpty)

		let resaved = await database.updateAsync(parsedItems: [parsedItem("a")], feedID: feedID)
		let article = try #require(resaved.new?.first)
		#expect(!article.status.starred)
		#expect(!article.status.read)
	}
}

private extension RetentionTests {

	func parsedItem(_ uniqueID: String, datePublished: Date? = nil) -> ParsedItem {
		ParsedItem(syncServiceID: nil, uniqueID: uniqueID, feedURL: feedID, url: "https://example.com/\(uniqueID)", externalURL: nil, title: uniqueID, language: nil, contentHTML: "<p>\(uniqueID)</p>", contentText: nil, markdown: nil, summary: nil, imageURL: nil, bannerImageURL: nil, datePublished: datePublished, dateModified: nil, authors: nil, tags: nil, attachments: nil)
	}
}
