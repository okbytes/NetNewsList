//
//  Account+Backup.swift
//  Account
//
//  The whole reading list as one JSON document, for backups kept outside iCloud.
//  Sync mirrors every change to every device, a mistaken delete included; a dated
//  snapshot doesn’t. See Technotes/NetNewsList/ReadingList.md, “Backups”.
//

import Foundation
import Articles

/// A snapshot of the reading list: everything needed to put each article back.
struct ReadingListBackup: Encodable {

	struct Article: Encodable {
		let articleID: String
		/// The canonical address, which is also the article’s identity.
		let url: String
		/// The address as it was saved, when it differs.
		let externalURL: String?
		let title: String?
		/// The saved text. Nil means the page hadn’t been extracted yet.
		let contentHTML: String?
		let summary: String?
		let imageURL: String?
		let authors: [String]?
		/// When the article was saved, by the same rule every list sorts by.
		let dateSaved: Date
		/// In the Archive rather than the Queue.
		let isArchived: Bool
	}

	let formatVersion = 1
	/// Oldest first.
	let articles: [Article]

	/// Readable, and stable: the same reading list always encodes to the same bytes.
	func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		encoder.dateEncodingStrategy = .custom { date, encoder in
			var container = encoder.singleValueContainer()
			try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
		}
		return try encoder.encode(self)
	}
}

public extension Account {

	/// Every saved article, Queue and Archive, as backup JSON.
	func readingListBackupData() async throws -> Data {
		var articles = [ReadingListBackup.Article]()
		if let feed = readingListFeed {
			articles = await fetchArticlesAsync(.feed(feed)).map { article in
				ReadingListBackup.Article(articleID: article.articleID,
										  url: article.uniqueID,
										  externalURL: article.rawExternalLink,
										  title: article.title,
										  contentHTML: article.contentHTML,
										  summary: article.summary,
										  imageURL: article.rawImageLink,
										  authors: article.authors?.compactMap(\.name).sorted(),
										  dateSaved: article.datePublished ?? article.dateModified ?? article.status.dateArrived,
										  isArchived: article.status.read)
			}
		}
		articles.sort { ($0.dateSaved, $0.articleID) < ($1.dateSaved, $1.articleID) }
		return try ReadingListBackup(articles: articles).encoded()
	}
}
