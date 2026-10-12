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
		menu.addItem(withTitle: NSLocalizedString("Add Article…", comment: "Command"), action: #selector(AppDelegate.showAddArticleWindow(_:)), keyEquivalent: "")
		return menu
	}
}
