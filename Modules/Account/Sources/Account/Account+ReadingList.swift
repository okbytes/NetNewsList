//
//  Account+ReadingList.swift
//  Account
//
//  The reading-list API. Every saved article lives in one permanent feed,
//  `netnewslist://reading-list`, so the existing article storage, queries and
//  iCloud sync work unchanged. See Technotes/NetNewsList/Plan.md, D2.
//

import Foundation
import os
import RSCore
import Articles
import RSParser

/// What extraction produced for a page. `contentHTML == nil` means extraction is pending.
public struct ReadingListContent: Sendable {
	public var title: String?
	public var contentHTML: String?
	public var summary: String?
	public var imageURL: String?
	public var byline: String?

	public init(title: String? = nil, contentHTML: String? = nil, summary: String? = nil, imageURL: String? = nil, byline: String? = nil) {
		self.title = title
		self.contentHTML = contentHTML
		self.summary = summary
		self.imageURL = imageURL
		self.byline = byline
	}
}

public enum ReadingListError: LocalizedError, Sendable {
	case invalidURL(String)
	case articleNotFound

	public var errorDescription: String? {
		switch self {
		case .invalidURL(let urlString):
			return String(format: NSLocalizedString("“%@” isn’t a web page address that can be saved.", comment: "Reading list: invalid URL"), urlString)
		case .articleNotFound:
			return NSLocalizedString("The article is no longer in the reading list.", comment: "Reading list: article not found")
		}
	}
}

/// The operations the app uses to change the reading list. Kept narrow so the
/// storage and sync behind it can be replaced without touching the UI.
@MainActor public protocol ReadingListStore: AnyObject {
	@discardableResult
	func saveArticle(url urlString: String, title: String?, content: ReadingListContent?) async throws -> Article
	func updateArticleContent(articleID: String, content: ReadingListContent) async throws
	func deleteArticles(articleIDs: Set<String>) async
	func pendingExtractionArticleIDs() async -> Set<String>
}

extension Account: ReadingListStore {

	nonisolated public static let readingListFeedURL = "netnewslist://reading-list"
	private static let readingListLogger = Logger(subsystem: Logger.nnwSubsystem, category: "ReadingList")

	/// The feed holding every saved article.
	public var readingListFeed: Feed? {
		existingFeed(withURL: Self.readingListFeedURL)
	}

	/// Creates the reading-list feed on this device if it is missing. The feed’s URL, feed ID
	/// and iCloud record name are fixed, so every device ends up with the same feed.
	@discardableResult
	func ensureReadingListFeed() -> Feed {
		if let feed = readingListFeed {
			if feed.externalID == nil {
				feed.externalID = Self.readingListFeedURL.md5String
			}
			return feed
		}
		Self.readingListLogger.info("ReadingList: creating the reading-list feed")
		let feed = createFeed(with: NSLocalizedString("Reading List", comment: "Reading list feed name"), url: Self.readingListFeedURL, feedID: Self.readingListFeedURL, homePageURL: nil)
		feed.externalID = Self.readingListFeedURL.md5String
		addFeedToTreeAtTopLevel(feed)
		return feed
	}

	/// Saves a page. Saving a page that is already in the list moves it back to the
	/// inbox and keeps its content; it never replaces content with nothing.
	@discardableResult
	public func saveArticle(url urlString: String, title: String?, content: ReadingListContent?) async throws -> Article {
		guard let canonical = URLCanonicalizer.canonicalString(for: urlString) else {
			throw ReadingListError.invalidURL(urlString)
		}
		let feed = ensureReadingListFeed()
		let articleID = Article.calculatedArticleID(feedID: feed.feedID, uniqueID: canonical)

		if let existing = await fetchArticlesAsync(.articleIDs([articleID])).first {
			Self.readingListLogger.info("ReadingList: already saved \(canonical, privacy: .public)")
			if existing.status.read {
				try await markArticles(articleIDs: [articleID], statusKey: .read, flag: false)
			}
			if let content, content.contentHTML != nil, existing.contentHTML == nil {
				try await updateArticleContent(articleID: articleID, content: content)
			}
			return await fetchArticlesAsync(.articleIDs([articleID])).first ?? existing
		}

		let trimmedOriginal = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		let item = parsedItem(uniqueID: canonical, feed: feed, externalURL: trimmedOriginal == canonical ? nil : trimmedOriginal, title: content?.title ?? title, content: content)
		let changes = await updateAsync(feedID: feed.feedID, parsedItems: [item])
		guard let article = changes.new?.first else {
			throw ReadingListError.articleNotFound
		}
		Self.readingListLogger.info("ReadingList: saved \(canonical, privacy: .public)")
		await cloudKitDelegate?.storeAndSendArticleChanges(new: [article], updated: nil, deleted: nil)
		return article
	}

	/// Stores extracted content for a saved article and uploads it.
	public func updateArticleContent(articleID: String, content: ReadingListContent) async throws {
		guard let article = await fetchArticlesAsync(.articleIDs([articleID])).first,
			  let feed = readingListFeed else {
			throw ReadingListError.articleNotFound
		}
		let item = parsedItem(uniqueID: article.uniqueID, feed: feed, externalURL: article.rawExternalLink, title: content.title ?? article.title, content: content)
		let changes = await updateAsync(feedID: feed.feedID, parsedItems: [item])
		guard let updated = changes.updated, !updated.isEmpty else {
			return
		}
		await cloudKitDelegate?.storeAndSendArticleChanges(new: nil, updated: updated, deleted: nil)
	}

	/// Removes articles here and, through iCloud, from every other device.
	public func deleteArticles(articleIDs: Set<String>) async {
		guard !articleIDs.isEmpty else {
			return
		}
		let articles = await fetchArticlesAsync(.articleIDs(articleIDs))
		await cloudKitDelegate?.storeAndSendArticleChanges(new: nil, updated: nil, deleted: articles)
		await delete(articleIDs: articleIDs)

		var feeds = Set<Feed>()
		if let feed = readingListFeed {
			feeds.insert(feed)
			updateUnreadCounts(feeds: feeds)
		}
		NotificationCenter.default.post(name: .AccountDidDownloadArticles, object: self, userInfo: [UserInfoKey.feeds: feeds])
	}

	/// Saved articles whose content has not been extracted yet.
	public func pendingExtractionArticleIDs() async -> Set<String> {
		guard let feed = readingListFeed else {
			return Set<String>()
		}
		return await database.fetchArticleIDsWithoutContentAsync(feedIDs: [feed.feedID])
	}
}

private extension Account {

	var cloudKitDelegate: CloudKitAccountDelegate? {
		delegate as? CloudKitAccountDelegate
	}

	/// Saved articles carry no publication date, so every date-based sort and query
	/// treats them by the date they were saved, and none arrives already read.
	func parsedItem(uniqueID: String, feed: Feed, externalURL: String?, title: String?, content: ReadingListContent?) -> ParsedItem {
		var authors: Set<ParsedAuthor>?
		if let byline = content?.byline, !byline.isEmpty {
			authors = [ParsedAuthor(name: byline, url: nil, avatarURL: nil, emailAddress: nil)]
		}
		return ParsedItem(syncServiceID: nil,
						  uniqueID: uniqueID,
						  feedURL: feed.feedID,
						  url: uniqueID,
						  externalURL: externalURL,
						  title: title,
						  language: nil,
						  contentHTML: content?.contentHTML,
						  contentText: nil,
						  markdown: nil,
						  summary: content?.summary,
						  imageURL: content?.imageURL,
						  bannerImageURL: nil,
						  datePublished: nil,
						  dateModified: nil,
						  authors: authors,
						  tags: nil,
						  attachments: nil)
	}
}
