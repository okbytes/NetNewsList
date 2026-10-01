//
//  ArchiveFeedDelegate.swift
//  NetNewsList
//
//  Archive: saved articles that have been read. Archiving is marking as read.
//

import Foundation
import RSCore
import Articles
import Account
import Images

@MainActor struct ArchiveFeedDelegate: SmartFeedDelegate {

	var sidebarItemID: SidebarItemIdentifier? {
		SidebarItemIdentifier.smartFeed(String(describing: ArchiveFeedDelegate.self))
	}

	let nameForDisplay = NSLocalizedString("Archive", comment: "Archive smart feed title")
	let fetchType: FetchType = .read(nil)

	var smallIcon: IconImage? {
		Assets.Images.archiveFeed
	}

	/// Everything here is read, so there is never an unread count to show.
	func fetchUnreadCount(account: Account) async -> Int {
		0
	}
}
