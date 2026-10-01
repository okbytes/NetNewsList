//
//  SidebarTreeControllerDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/24/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSTree
import Articles
import Account

/// The sidebar is one group of fixed lists: Inbox, Starred, Archive and All.
/// Feeds, folders and accounts are never shown.
@MainActor final class SidebarTreeControllerDelegate: TreeControllerDelegate {

	func treeController(treeController: TreeController, childNodesFor node: Node) -> [Node]? {
		if node.isRoot {
			let smartFeedsNode = node.existingOrNewChildNode(with: SmartFeedsController.shared)
			smartFeedsNode.canHaveChildNodes = true
			smartFeedsNode.isGroupItem = true
			return [smartFeedsNode]
		}
		if node.representedObject is SmartFeedsController {
			return SmartFeedsController.shared.smartFeeds.map { node.existingOrNewChildNode(with: $0 as AnyObject) }
		}
		return nil
	}
}
