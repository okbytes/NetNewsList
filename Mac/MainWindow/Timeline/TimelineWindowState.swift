//
//  TimelineWindowState.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 12/16/23.
//  Copyright © 2023 Ranchero Software. All rights reserved.
//

import Foundation

final class TimelineWindowState: NSObject, NSSecureCoding {

	static let supportsSecureCoding = true

	let selectedArticleID: String?
	// Nil when the state was saved before sorting became per-window, or was sorted by a field that's gone.
	let sortParameters: ArticleSortParameters?

	// State saved before the read filter was removed also has readArticlesFilterStateKeys and
	// readArticlesFilterStateValues, and older state has selectedAccountID; they're ignored.
	init(selectedArticleID: String? = nil, sortParameters: ArticleSortParameters? = nil) {
		self.selectedArticleID = selectedArticleID
		self.sortParameters = sortParameters
	}

	private struct Key {
		static let selectedArticleID = "selectedArticleID"
		static let sortKey = "sortKey"
		static let sortDirection = "sortDirection"
		// Read only, to migrate state saved when Group By Feed was a separate setting.
		static let groupByFeed = "groupByFeed"
	}

	required init?(coder: NSCoder) {
		selectedArticleID = coder.decodeObject(of: NSString.self, forKey: Key.selectedArticleID) as? String

		// Sorting by Unread or Starred is gone, so a window sorted that way starts over with the default sort.
		if let rawSortKey = coder.decodeObject(of: NSString.self, forKey: Key.sortKey) as? String, let sortKey = ArticleSortKey(rawValue: rawSortKey), sortKey != .unread, sortKey != .starred {
			// Anything other than ascending — including a missing key — means descending.
			let direction: ComparisonResult = coder.decodeInteger(forKey: Key.sortDirection) == ComparisonResult.orderedAscending.rawValue ? .orderedAscending : .orderedDescending
			if sortKey == .date && coder.decodeBool(forKey: Key.groupByFeed) {
				// Group By Feed became sorting by feed, A to Z.
				sortParameters = ArticleSortParameters(key: .feed, direction: .orderedAscending)
			} else {
				sortParameters = ArticleSortParameters(key: sortKey, direction: direction)
			}
		} else {
			sortParameters = nil
		}
	}

	func encode(with coder: NSCoder) {
		coder.encode(selectedArticleID, forKey: Key.selectedArticleID)
		if let sortParameters {
			coder.encode(sortParameters.key.rawValue, forKey: Key.sortKey)
			coder.encode(sortParameters.direction.rawValue, forKey: Key.sortDirection)
		}
	}

	override var description: String {
		let sort: String
		if let sortParameters {
			sort = "\(sortParameters.key.rawValue) \(sortParameters.direction.rawValue)"
		} else {
			sort = "nil"
		}
		return "TimelineWindowState: articleID=\(selectedArticleID ?? "nil"), sort=\(sort)"
	}
}
