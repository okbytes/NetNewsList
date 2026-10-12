//
//  RootSplitViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 9/4/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import Account

final class RootSplitViewController: UISplitViewController {

	var coordinator: SceneCoordinator!

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		coordinator.resetFocus()
	}

	/// Show a column for programmatic navigation.
	/// Pass `bypassDisplayModeRestriction: true` for user-initiated navigation, so it can
	/// reveal a column the display-mode suppression below would otherwise keep hidden.
	/// <https://github.com/Ranchero-Software/NetNewsWire/issues/3138>
	func showColumn(_ column: UISplitViewController.Column, bypassDisplayModeRestriction: Bool = false) {
		guard !coordinator.isNavigationDisabled else { return }

		/// Always show the column on iPhone
		if UIDevice.current.userInterfaceIdiom == .phone {
			show(column)
			return
		}

		/// Selecting a list or an article doesn't bring back a list the user hid to read the article full width.
		if !bypassDisplayModeRestriction && column == .primary && displayMode == .secondaryOnly {
			return
		}

		show(column)
	}

	// MARK: Keyboard Shortcuts

	/// Space bar: scrolls the article.
	@objc func scrollArticle(_ sender: Any?) {
		coordinator.scrollDown()
	}

	@objc func scrollUp(_ sender: Any?) {
		coordinator.scrollUp()
	}

	@objc func openInBrowser(_ sender: Any?) {
		coordinator.showBrowserForCurrentArticle()
	}

	@objc func addNewArticle(_ sender: Any?) {
		coordinator.showAddArticle()
	}

	@objc func sync(_ sender: Any?) {
		appDelegate.manualRefresh(errorHandler: ErrorHandler.present(self))
	}

	@objc func goToQueue(_ sender: Any?) {
		coordinator.selectQueue()
	}

	@objc func goToArchive(_ sender: Any?) {
		coordinator.selectArchive()
	}

	@objc func goToSettings(_ sender: Any?) {
		coordinator.showSettings()
	}

	@objc func toggleRead(_ sender: Any?) {
		coordinator.toggleReadForCurrentArticle()
	}
}
