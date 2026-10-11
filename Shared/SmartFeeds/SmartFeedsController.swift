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
import Articles

@MainActor final class SmartFeedsController: DisplayNameProvider, ContainerIdentifiable {
	nonisolated let containerID: ContainerIdentifier? = ContainerIdentifier.smartFeedController

	public static let shared = SmartFeedsController()
	let nameForDisplay = NSLocalizedString("Reading List", comment: "Sidebar group title")

	var smartFeeds = [SidebarItem]()
	/// Queue: everything saved and not yet archived.
	let unreadFeed = UnreadFeed()
	let archiveFeed = SmartFeed(delegate: ArchiveFeedDelegate())

	private init() {
		self.smartFeeds = [unreadFeed, archiveFeed]
	}

	/// The list an article is in: Archive once it's archived (read), Queue until then.
	func list(for article: Article) -> PseudoFeed {
		article.status.read ? archiveFeed : unreadFeed
	}

	func find(by identifier: SidebarItemIdentifier) -> PseudoFeed? {
		switch identifier {
		case .smartFeed(let stringIdentifer):
			switch stringIdentifer {
			case String(describing: UnreadFeed.self):
				return unreadFeed
			case String(describing: ArchiveFeedDelegate.self):
				return archiveFeed
			default:
				return nil
			}
		default:
			return nil
		}
	}

}
