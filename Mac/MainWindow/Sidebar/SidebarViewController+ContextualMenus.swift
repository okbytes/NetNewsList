//
//  SidebarViewController+ContextualMenus.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 1/28/18.
//  Copyright © 2018 Ranchero Software. All rights reserved.
//

import AppKit
import Articles
import Account
import RSCore

extension SidebarViewController {

	func menu(for objects: [Any]?) -> NSMenu? {
		let menu = NSMenu(title: "")
		let lists = (objects ?? []).compactMap { $0 as? PseudoFeed }
		if lists.contains(where: { $0.unreadCount > 0 }) {
			menu.addItem(menuItem(NSLocalizedString("Archive All", comment: "Command"), #selector(archiveAllFromContextualMenu(_:)), lists))
			menu.addItem(.separator())
		}
		menu.addItem(withTitle: NSLocalizedString("Add Article…", comment: "Command"), action: #selector(AppDelegate.showAddArticleWindow(_:)), keyEquivalent: "")
		return menu
	}

	@objc func archiveAllFromContextualMenu(_ sender: Any?) {
		guard let menuItem = sender as? NSMenuItem, let lists = menuItem.representedObject as? [PseudoFeed] else {
			return
		}
		let articles = lists.reduce(into: Set<Article>()) { $0.formUnion($1.fetchUnreadArticles()) }
		guard let undoManager, let markReadCommand = MarkStatusCommand(initialArticles: Array(articles), markingRead: true, undoManager: undoManager) else {
			return
		}
		runCommand(markReadCommand)
	}
}

private extension SidebarViewController {

	func menuItem(_ title: String, _ action: Selector, _ representedObject: Any) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.representedObject = representedObject
		item.target = self
		return item
	}
}
