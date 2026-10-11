//
//  SidebarWindowState.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 12/16/23.
//  Copyright © 2023 Ranchero Software. All rights reserved.
//

import Foundation

final class SidebarWindowState: NSObject, NSSecureCoding {
	static let supportsSecureCoding = true

	let expandedContainers: [[String: String]]
	let selectedFeeds: [[String: String]]

	// State saved before the read filter was removed also has an isReadFiltered key, which is ignored.
	init(expandedContainers: [[String: String]], selectedFeeds: [[String: String]]) {
		self.expandedContainers = expandedContainers
		self.selectedFeeds = selectedFeeds
	}

	private struct Key {
		static let expandedContainers = "expandedContainers"
		static let selectedFeeds = "selectedFeeds"
	}

	required init?(coder: NSCoder) {
		expandedContainers = coder.decodeObject(of: [NSArray.self, NSDictionary.self, NSString.self], forKey: Key.expandedContainers) as? [[String: String]] ?? []
		selectedFeeds = coder.decodeObject(of: [NSArray.self, NSDictionary.self, NSString.self], forKey: Key.selectedFeeds) as? [[String: String]] ?? []
	}

	func encode(with coder: NSCoder) {
		coder.encode(expandedContainers, forKey: Key.expandedContainers)
		coder.encode(selectedFeeds, forKey: Key.selectedFeeds)
	}

	override var description: String {
		"SidebarWindowState: expandedContainers=\(expandedContainers), selectedFeeds=\(selectedFeeds)"
	}
}
