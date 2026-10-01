//
//  ReadingListTests.swift
//  AccountTests
//

import Foundation
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

	@Test func savedArticleIsUnreadInTheReadingListWithNoPublishDate() async throws {
		let account = accountManager.createAccount(type: .cloudKit)
		defer {
			accountManager.deleteAccount(account)
		}

		let article = try await account.saveArticle(url: "https://Example.com/post?utm_source=x", title: "Post", content: nil)

		#expect(article.feedID == Account.readingListFeedURL)
		#expect(article.uniqueID == "https://example.com/post")
		#expect(article.rawExternalLink == "https://Example.com/post?utm_source=x")
		#expect(article.datePublished == nil)
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
