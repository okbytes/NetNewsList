//
//  ReadingListTests.swift
//  AccountTests
//

import Foundation
import CloudKit
import Testing
import Articles
@testable import Account

@MainActor struct URLCanonicalizerTests {

	private struct Vectors: Decodable {
		struct Vector: Decodable {
			let input: String
			let output: String?
		}
		let vectors: [Vector]
	}

	@Test func sharedVectors() throws {
		let url = try #require(Bundle.module.url(forResource: "url-canonicalization", withExtension: "json", subdirectory: "Resources"))
		let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).vectors
		#expect(!vectors.isEmpty)
		for vector in vectors {
			#expect(URLCanonicalizer.canonicalString(for: vector.input) == vector.output, "input: \(vector.input)")
		}
	}
}

@MainActor struct ReadingListTests {

	private let accountManager = TestAccountManager()

	@Test func savedArticleIsUnreadInTheReadingListWithItsSavedDate() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		// Shared earlier; the app is only now processing the share.
		let dateSaved = Date(timeIntervalSince1970: 1_790_000_000)
		let article = try await account.saveArticle(url: "https://Example.com/post?utm_source=x", title: "Post", content: nil, dateSaved: dateSaved)

		#expect(article.feedID == Account.readingListFeedURL)
		#expect(article.uniqueID == "https://example.com/post")
		#expect(article.rawExternalLink == "https://Example.com/post?utm_source=x")
		// The saved date goes to iCloud as datePublished. dateArrived doesn't sync: each device sets
		// it when the article reaches it, so a new device would show its own install time.
		#expect(article.datePublished == dateSaved)
		#expect(!article.status.read)
		#expect(article.contentHTML == nil)
		#expect(await account.pendingExtractionArticleIDs() == [article.articleID])
	}

	@Test func savingTheSamePageTwiceKeepsOneArticleAndItsContent() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		let first = try await account.saveArticle(url: "https://example.com/post", title: "Post", content: ReadingListContent(contentHTML: "<p>Body</p>"))
		try await account.markArticles(articleIDs: [first.articleID], statusKey: .read, flag: true)

		let second = try await account.saveArticle(url: "https://example.com/post/#top", title: nil, content: nil)

		#expect(second.articleID == first.articleID)
		#expect(second.contentHTML == "<p>Body</p>")
		#expect(!second.status.read)
		let feed = try #require(account.readingListFeed)
		#expect(await account.fetchArticlesAsync(.feed(feed)).count == 1)
	}

	@Test func extractedContentReplacesPending() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		let saved = try await account.saveArticle(url: "https://example.com/post", title: "Link title", content: nil)
		try await account.updateArticleContent(articleID: saved.articleID, content: ReadingListContent(title: "Real title", contentHTML: "<p>Body</p>", summary: "Body"))

		let article = try #require(await account.fetchArticlesAsync(.articleIDs([saved.articleID])).first)
		#expect(article.title == "Real title")
		#expect(article.contentHTML == "<p>Body</p>")
		#expect(await account.pendingExtractionArticleIDs().isEmpty)
	}

	@Test func failedExtractionsTitleKeepsTheBody() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		// A Shortcut saved the page with a body and no title; a Retry then found only a bot
		// check, whose title is all a failed extraction keeps.
		let saved = try await account.saveArticle(url: "https://example.com/post", title: nil, content: ReadingListContent(contentHTML: "<p>Body</p>"))
		try await account.updateArticleContent(articleID: saved.articleID, content: ReadingListContent(title: "Just a moment"))

		let article = try #require(await account.fetchArticlesAsync(.articleIDs([saved.articleID])).first)
		#expect(article.contentHTML == "<p>Body</p>")
		#expect(article.title == nil)
	}

	@Test func extractedContentKeepsAnImportedSaveDate() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		// Imported from Matter on another device: the date saved there arrives as datePublished.
		typealias Fields = CloudKitArticlesZone.CloudKitArticle.Fields
		let dateSaved = Date(timeIntervalSince1970: 1_780_000_000)
		let feed = account.ensureReadingListFeed()
		let record = CKRecord(recordType: CloudKitArticlesZone.CloudKitArticle.recordType)
		record[Fields.feedURL] = feed.feedID
		record[Fields.uniqueID] = "https://example.com/post"
		record[Fields.url] = "https://example.com/post"
		record[Fields.title] = "Post"
		record[Fields.datePublished] = dateSaved
		let item = try #require(makeParsedItem(record))
		let imported = try #require(await account.updateAsync(feedID: feed.feedID, parsedItems: [item]).new?.first)

		// Losing it would move the article to the end of the Queue on every device.
		try await account.updateArticleContent(articleID: imported.articleID, content: ReadingListContent(contentHTML: "<p>Body</p>"))

		let article = try #require(await account.fetchArticlesAsync(.articleIDs([imported.articleID])).first)
		#expect(article.contentHTML == "<p>Body</p>")
		#expect(article.datePublished == dateSaved)
	}

	@Test func backupHoldsEveryArticleWithItsTextDateAndList() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		let queued = try await account.saveArticle(url: "https://example.com/queued", title: "Queued", content: ReadingListContent(contentHTML: "<p>Queued body</p>"))
		let archived = try await account.saveArticle(url: "https://example.com/archived", title: "Archived", content: nil)
		try await account.markArticles(articleIDs: [archived.articleID], statusKey: .read, flag: true)

		let data = try await account.readingListBackupData()
		let backup = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		let articles = try #require(backup["articles"] as? [[String: Any]])
		#expect(articles.compactMap { $0["url"] as? String } == ["https://example.com/queued", "https://example.com/archived"])
		#expect(articles.map { $0["isArchived"] as? Bool } == [false, true])
		#expect(articles[0]["contentHTML"] as? String == "<p>Queued body</p>")
		#expect(articles[0]["dateSaved"] as? String == queued.datePublished?.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
		// Unchanged lists give identical bytes, so an unchanged day writes no new backup.
		#expect(try await account.readingListBackupData() == data)
	}

	@Test func archiveListsReadArticles() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		let kept = try await account.saveArticle(url: "https://example.com/inbox", title: nil, content: nil)
		let archived = try await account.saveArticle(url: "https://example.com/archived", title: nil, content: nil)
		try await account.markArticles(articleIDs: [archived.articleID], statusKey: .read, flag: true)

		#expect(await account.fetchArticlesAsync(.read()).map(\.articleID) == [archived.articleID])
		#expect(await account.fetchArticlesAsync(.unread()).map(\.articleID) == [kept.articleID])
	}

	@Test func deleteRemovesTheArticle() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		let saved = try await account.saveArticle(url: "https://example.com/post", title: nil, content: nil)
		let deletion = DeletedArticleIDs()
		let observer = NotificationCenter.default.addObserver(forName: .AccountDidDeleteArticles, object: account, queue: nil) { note in
			deletion.articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>
		}
		defer {
			NotificationCenter.default.removeObserver(observer)
		}
		await account.deleteArticles(articleIDs: [saved.articleID])

		#expect(await account.fetchArticlesAsync(.articleIDs([saved.articleID])).isEmpty)
		// Timelines remove deleted articles when told; their merge would otherwise keep them.
		#expect(deletion.articleIDs == [saved.articleID])

		// A read status of the page arrives from iCloud without the page (another device archived it
		// before it saw the delete). Saving the page again still puts it in the Queue.
		await account.markAsReadAsync(articleIDs: [saved.articleID])
		let savedAgain = try await account.saveArticle(url: "https://example.com/post", title: nil, content: nil)
		#expect(!savedAgain.status.read)
	}

	@Test func invalidURLIsRejected() async {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		await #expect(throws: ReadingListError.self) {
			try await account.saveArticle(url: "ftp://example.com/file", title: nil, content: nil)
		}
	}
}

private final class DeletedArticleIDs: @unchecked Sendable {
	var articleIDs: Set<String>?
}
