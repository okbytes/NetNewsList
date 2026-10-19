//
//  ArticleAssetCoordinator.swift
//  NetNewsList
//
//  Keeps the local image store in step with the reading list: downloads images
//  when an article gets its body (saved here or arriving from another device),
//  deletes them with the article, and at launch and then daily removes folders
//  whose article is gone, drops the images of articles in the Archive for 30 days
//  (opening one downloads them again) and fills in the inbox’s missing images.
//

import Foundation
import os
import RSCore
import RSWeb
import Articles
import Account

@MainActor final class ArticleAssetCoordinator {

	static let shared = ArticleAssetCoordinator()

	/// How many inbox articles get their missing images filled in at launch.
	private static let launchPrefetchLimit = 50

	/// How long an article stays in the Archive on this device before its images go.
	static let archivedImagesLifetime: TimeInterval = 30 * 24 * 60 * 60

	private static let tidyUpInterval: Duration = .seconds(24 * 60 * 60)

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleAssetCoordinator")

	private var isStarted = false

	func start() {
		guard !isStarted else {
			return
		}
		isStarted = true
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDeleteArticles(_:)), name: .AccountDidDeleteArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(5))
			while !Task.isCancelled {
				await self.tidyUp()
				try? await Task.sleep(for: Self.tidyUpInterval)
			}
		}
	}

	@objc func accountDidDownloadArticles(_ note: Notification) {
		var articles = Set<Article>()
		for key in [Account.UserInfoKey.newArticles, Account.UserInfoKey.updatedArticles] {
			if let changed = note.userInfo?[key] as? Set<Article> {
				articles.formUnion(changed)
			}
		}
		prefetch(articles.filter { $0.contentHTML != nil })
	}

	@objc func accountDidDeleteArticles(_ note: Notification) {
		guard let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String> else {
			return
		}
		Task {
			await ArticleAssetStore.shared.deleteAssets(articleIDs: articleIDs)
			await ArticleAssetStore.shared.noteNotArchived(articleIDs: articleIDs)
		}
	}

	/// Notes when articles go into the Archive, here or on another device. One moved
	/// back to the Queue gets its images again, in case they were dropped.
	@objc func statusesDidChange(_ note: Notification) {
		guard let statusKey = note.userInfo?[Account.UserInfoKey.statusKey] as? ArticleStatus.Key, statusKey == .read,
			  let isArchived = note.userInfo?[Account.UserInfoKey.statusFlag] as? Bool,
			  let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>, !articleIDs.isEmpty else {
			return
		}
		Task { @MainActor in
			if isArchived {
				await ArticleAssetStore.shared.noteArchived(articleIDs: articleIDs)
				return
			}
			await ArticleAssetStore.shared.noteNotArchived(articleIDs: articleIDs)
			let articles = await account.fetchArticlesAsync(.articleIDs(articleIDs))
			prefetch(articles.filter { $0.contentHTML != nil })
		}
	}
}

private extension ArticleAssetCoordinator {

	var account: Account {
		AccountManager.shared.defaultAccount
	}

	func prefetch(_ articles: some Collection<Article>) {
		guard !articles.isEmpty else {
			return
		}
		let userAgent = UserAgent.browserUserAgent
		let jobs = articles.compactMap { article -> (articleID: String, html: String, pageURL: String?)? in
			guard let html = article.contentHTML else {
				return nil
			}
			return (article.articleID, html, article.preferredLink)
		}
		Task {
			let longArchived = await ArticleAssetStore.shared.articleIDsArchived(before: Self.archivedImagesCutoff)
			for job in jobs where !longArchived.contains(job.articleID) {
				await ArticleAssetStore.shared.prefetch(articleID: job.articleID, html: job.html, pageURL: job.pageURL, userAgent: userAgent)
			}
		}
	}

	static var archivedImagesCutoff: Date {
		Date().addingTimeInterval(-archivedImagesLifetime)
	}

	func tidyUp() async {
		let store = ArticleAssetStore.shared
		let storedArticleIDs = await store.storedArticleIDs()
		let notedArchivedArticleIDs = await store.archivedArticleIDs()
		let articleIDs = storedArticleIDs.union(notedArchivedArticleIDs)
		if !articleIDs.isEmpty {
			let articles = await account.fetchArticlesAsync(.articleIDs(articleIDs))
			let existing = Set(articles.map(\.articleID))
			let orphans = storedArticleIDs.subtracting(existing)
			if !orphans.isEmpty {
				await store.deleteAssets(articleIDs: orphans)
			}

			let archived = Set(articles.filter(\.status.read).map(\.articleID))
			await store.noteNotArchived(articleIDs: notedArchivedArticleIDs.subtracting(archived))
			await store.noteArchived(articleIDs: archived)

			// Only articles still in the Archive: a Queue article's images are never dropped.
			let dropped = await store.deleteAssetsOfArticlesArchived(before: Self.archivedImagesCutoff, among: archived.intersection(storedArticleIDs))
			if !dropped.isEmpty {
				Self.logger.info("ArticleAssetCoordinator: dropped the images of \(dropped.count) articles in the Archive for 30 days")
			}
		}
		let inbox = await account.fetchArticlesAsync(.unread(Self.launchPrefetchLimit))
		prefetch(inbox.filter { $0.contentHTML != nil })
	}
}
