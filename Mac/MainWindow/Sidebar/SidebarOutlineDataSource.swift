//
//  SidebarOutlineDataSource.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/12/18.
//  Copyright © 2018 Ranchero Software. All rights reserved.
//

import AppKit
import RSTree
import RSCore

@objc @MainActor final class SidebarOutlineDataSource: NSObject, NSOutlineViewDataSource {

	let treeController: TreeController

	init(treeController: TreeController) {
		self.treeController = treeController
	}

	// MARK: - NSOutlineViewDataSource

	func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		nodeForItem(item).numberOfChildNodes
	}

	func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		nodeForItem(item).childNodes[index]
	}

	func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
		nodeForItem(item).canHaveChildNodes
	}

	// MARK: - Drops

	/// A web address dropped anywhere on the sidebar is saved.
	func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
		guard !DroppedWebPages.pages(on: info.draggingPasteboard).isEmpty else {
			return []
		}
		outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
		return .copy
	}

	func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
		DroppedWebPages.save(DroppedWebPages.pages(on: info.draggingPasteboard))
	}
}

private extension SidebarOutlineDataSource {

	func nodeForItem(_ item: Any?) -> Node {
		(item as? Node) ?? treeController.rootNode
	}
}
