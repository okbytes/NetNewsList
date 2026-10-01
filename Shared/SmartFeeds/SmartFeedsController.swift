//
//  SmartFeedsController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 12/16/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import Foundation
import RSCore
import Account

@MainActor final class SmartFeedsController: DisplayNameProvider, ContainerIdentifiable {
	nonisolated let containerID: ContainerIdentifier? = ContainerIdentifier.smartFeedController

	public static let shared = SmartFeedsController()
	let nameForDisplay = NSLocalizedString("Reading List", comment: "Sidebar group title")

	var smartFeeds = [SidebarItem]()
	let unreadFeed = UnreadFeed()
	let starredFeed = SmartFeed(delegate: StarredFeedDelegate())
	let archiveFeed = SmartFeed(delegate: ArchiveFeedDelegate())
	let allArticlesFeed = SmartFeed(delegate: AllArticlesFeedDelegate())

	private init() {
		self.smartFeeds = [unreadFeed, starredFeed, archiveFeed, allArticlesFeed]
	}

	func find(by identifier: SidebarItemIdentifier) -> PseudoFeed? {
		switch identifier {
		case .smartFeed(let stringIdentifer):
			switch stringIdentifer {
			case String(describing: UnreadFeed.self):
				return unreadFeed
			case String(describing: StarredFeedDelegate.self):
				return starredFeed
			case String(describing: ArchiveFeedDelegate.self):
				return archiveFeed
			case String(describing: AllArticlesFeedDelegate.self):
				return allArticlesFeed
			default:
				return nil
			}
		default:
			return nil
		}
	}

}
