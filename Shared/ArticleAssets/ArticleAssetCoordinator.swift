//
//  ArticleAssetCoordinator.swift
//  NetNewsList
//
//  Keeps the local image store in step with the reading list: downloads images
//  when an article gets its body (saved here or arriving from another device),
//  deletes them with the article, and at launch removes folders whose article is
//  gone and fills in the inbox’s missing images.
//

import Foundation
import RSWeb
import Articles
import Account

@MainActor final class ArticleAssetCoordinator {

	static let shared = ArticleAssetCoordinator()

	/// How many inbox articles get their missing images filled in at launch.
	private static let launchPrefetchLimit = 50

	private var isStarted = false

	func start() {
		guard !isStarted else {
			return
		}
		isStarted = true
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDeleteArticles(_:)), name: .AccountDidDeleteArticles, object: nil)
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(5))
			await self.tidyUp()
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
			for job in jobs {
				await ArticleAssetStore.shared.prefetch(articleID: job.articleID, html: job.html, pageURL: job.pageURL, userAgent: userAgent)
			}
		}
	}

	func tidyUp() async {
		let storedArticleIDs = await ArticleAssetStore.shared.storedArticleIDs()
		if !storedArticleIDs.isEmpty {
			let existing = Set(await account.fetchArticlesAsync(.articleIDs(storedArticleIDs)).map(\.articleID))
			let orphans = storedArticleIDs.subtracting(existing)
			if !orphans.isEmpty {
				await ArticleAssetStore.shared.deleteAssets(articleIDs: orphans)
			}
		}
		let inbox = await account.fetchArticlesAsync(.unread(Self.launchPrefetchLimit))
		prefetch(inbox.filter { $0.contentHTML != nil })
	}
}
