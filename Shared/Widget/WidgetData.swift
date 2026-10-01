//
//  WidgetData.swift
//  NetNewsWire
//
//  Created by Stuart Breckenridge on 18/11/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation

struct WidgetData: Codable {
	let totalUnreadCount: Int
	let totalStarredCount: Int
	let unreadArticles: [LatestArticle]
	let starredArticles: [LatestArticle]
	let lastUpdateTime: Date
}

struct LatestArticle: Codable, Identifiable, Hashable {
	var id: String
	let feedTitle: String
	let articleTitle: String?
	let articleSummary: String?
	let feedIconPath: String? // Path to image data in shared container.
	let pubDate: String
}
