//
//  AccountsDetailViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 3/20/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import AppKit
import SwiftUI
import Account

final class AccountsDetailViewController: NSViewController {

	let account: Account

	init(account: Account) {
		self.account = account
		super.init(nibName: nil, bundle: nil)
	}

	public required init?(coder: NSCoder) {
		fatalError("AccountsDetailViewController does not support init(coder:)")
	}

	override func loadView() {
		let detailView = AccountsDetailView(account: account)
		let hostingView = NSHostingView(rootView: detailView)
		self.view = hostingView
	}
}
