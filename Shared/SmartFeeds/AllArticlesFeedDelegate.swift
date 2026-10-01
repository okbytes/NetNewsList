//
//  AllArticlesFeedDelegate.swift
//  NetNewsList
//
//  All: every saved article, read or not.
//

import Foundation
import RSCore
import Articles
import Account
import Images

@MainActor struct AllArticlesFeedDelegate: SmartFeedDelegate {

	var sidebarItemID: SidebarItemIdentifier? {
		SidebarItemIdentifier.smartFeed(String(describing: AllArticlesFeedDelegate.self))
	}

	let nameForDisplay = NSLocalizedString("All", comment: "All articles smart feed title")

	var fetchType: FetchType {
		guard let feed = AccountManager.shared.defaultAccount.readingListFeed else {
			return .articleIDs(Set<String>())
		}
		return .feed(feed)
	}

	var smallIcon: IconImage? {
		Assets.Images.allArticlesFeed
	}

	/// Inbox already shows the unread count; repeating it here would be noise.
	func fetchUnreadCount(account: Account) async -> Int {
		0
	}
}
