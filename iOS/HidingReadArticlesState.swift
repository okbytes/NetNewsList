//
//  HidingReadArticlesState.swift
//  NetNewsWire-iOS
//
//  Created by Brent Simmons on 12/8/25.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import Foundation
import Account

/// Which lists hide archived (read) articles. The Inbox always does; the others can be toggled.
@MainActor final class HidingReadArticlesState {
	private var smartFeedsHidingReadArticles = Set<String>()

	func copy(from stateRestorationInfo: StateRestorationInfo) {
		smartFeedsHidingReadArticles = stateRestorationInfo.smartFeedsHidingReadArticles
	}

	func save() {
		AppDefaults.shared.smartFeedsHidingReadArticles = smartFeedsHidingReadArticles
	}

	func toggleHidingReadArticles(for sidebarItemID: SidebarItemIdentifier) {
		assert(canToggleHidingReadArticles(for: sidebarItemID))
		guard canToggleHidingReadArticles(for: sidebarItemID), case .smartFeed(let id) = sidebarItemID else {
			return
		}

		if smartFeedsHidingReadArticles.contains(id) {
			smartFeedsHidingReadArticles.remove(id)
		} else {
			smartFeedsHidingReadArticles.insert(id)
		}
		save()
	}

	func isHidingReadArticles(for sidebarItemID: SidebarItemIdentifier) -> Bool {
		guard case .smartFeed(let id) = sidebarItemID else {
			return false
		}
		if isUnreadSmartFeed(sidebarItemID) {
			return true
		}
		return smartFeedsHidingReadArticles.contains(id)
	}

	func canToggleHidingReadArticles(for sidebarItemID: SidebarItemIdentifier) -> Bool {
		guard case .smartFeed = sidebarItemID else {
			return false
		}
		// The Inbox always hides read articles.
		return !isUnreadSmartFeed(sidebarItemID)
	}
}

private extension HidingReadArticlesState {

	func isUnreadSmartFeed(_ sidebarItemID: SidebarItemIdentifier) -> Bool {
		sidebarItemID == SmartFeedsController.shared.unreadFeed.sidebarItemID
	}
}
