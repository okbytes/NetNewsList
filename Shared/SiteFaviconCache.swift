//
//  SiteFaviconCache.swift
//  NetNewsList
//
//  Favicons by site. Every saved article belongs to one synthetic feed, so the
//  feed-keyed icon caches would give every article the same icon; this one asks
//  FaviconDownloader for the article’s own site instead. When an icon arrives,
//  FaviconDownloader posts .FaviconDidBecomeAvailable and views ask again.
//

import Foundation
import Articles
import Images

@MainActor final class SiteFaviconCache {

	static let shared = SiteFaviconCache()

	private var favicons = [String: IconImage]()

	init() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
	}

	func favicon(for article: Article) -> IconImage? {
		guard let host = article.siteHost, let homePageURL = article.siteHomePageURL else {
			return nil
		}
		if let favicon = FaviconDownloader.shared.favicon(withHomePageURL: homePageURL) {
			favicons[host] = favicon
			return favicon
		}
		// The downloader may have dropped its copy under memory pressure.
		return favicons[host]
	}

	/// Starts downloads for the sites of these articles, once per site.
	func prefetch(_ articles: [Article]) {
		var hostsSeen = Set<String>()
		for article in articles {
			guard let host = article.siteHost, hostsSeen.insert(host).inserted else {
				continue
			}
			_ = favicon(for: article)
		}
	}

	@objc func handleLowMemory(_ notification: Notification) {
		favicons.removeAll()
	}
}
