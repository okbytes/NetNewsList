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

	override var prefersStatusBarHidden: Bool {
		return coordinator.prefersStatusBarHidden
	}

	override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
		return .slide
	}

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

		/// In certain scenarios, we don't want to select a feed or article
		/// and have the display mode change as this interferes with state
		/// restoration of the feeds and timeline display modes.
		if !bypassDisplayModeRestriction {

			/// Don't show primary when the display mode is timeline + article or article only.
			if column == .primary && (displayMode == .oneBesideSecondary || displayMode == .secondaryOnly) {
				return
			}

			/// Don't show the timeline when the display mode is article only.
			if column == .supplementary && displayMode == .secondaryOnly {
				return
			}
		}

		show(column)
	}

	// MARK: Keyboard Shortcuts

	@objc func scrollOrGoToNextUnread(_ sender: Any?) {
		coordinator.scrollOrGoToNextUnread()
	}

	@objc func scrollUp(_ sender: Any?) {
		coordinator.scrollUp()
	}

	@objc func goToPreviousUnread(_ sender: Any?) {
		coordinator.selectPrevUnread()
	}

	@objc func nextUnread(_ sender: Any?) {
		coordinator.selectNextUnread()
	}

	@objc func markRead(_ sender: Any?) {
		coordinator.markAsReadForCurrentArticle()
	}

	@objc func markUnreadAndGoToNextUnread(_ sender: Any?) {
		coordinator.markAsUnreadForCurrentArticle()
		coordinator.selectNextUnread()
	}

	@objc func markAllAsReadAndGoToNextUnread(_ sender: Any?) {
		if !coordinator.isTimelineUnreadAvailable {
			coordinator.selectNextUnread()
			return
		}
		let articlesToMark = coordinator.articles
		let title = NSLocalizedString("Archive All", comment: "Command")

		let completion: () -> Void = { [weak self] in
			guard let self else {
				return
			}
			self.coordinator.markAsReadAndShowSidebar(articlesToMark) {
				self.coordinator.selectNextUnread()
			}
		}

		// Anchor to the Archive All button (keyboard shortcut has no source view).
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5370>
		if let markAllAsReadButton = (viewController(for: .supplementary) as? MainTimelineModernViewController)?.markAllAsReadButton {
			MarkAsReadAlertController.confirm(self, coordinator: coordinator, confirmTitle: title, sourceType: markAllAsReadButton, completion: completion)
		} else {
			MarkAsReadAlertController.confirm(self, coordinator: coordinator, confirmTitle: title, sourceType: view as UIView, completion: completion)
		}
	}

	@objc func markAboveAsRead(_ sender: Any?) {
		coordinator.markAboveAsRead()
	}

	@objc func markBelowAsRead(_ sender: Any?) {
		coordinator.markBelowAsRead()
	}

	@objc func markUnread(_ sender: Any?) {
		coordinator.markAsUnreadForCurrentArticle()
	}

	@objc func goToPreviousSubscription(_ sender: Any?) {
		coordinator.selectPrevFeed()
	}

	@objc func goToNextSubscription(_ sender: Any?) {
		coordinator.selectNextFeed()
	}

	@objc func openInBrowser(_ sender: Any?) {
		coordinator.showBrowserForCurrentArticle()
	}

	@objc func openInAppBrowser(_ sender: Any?) {
		coordinator.showInAppBrowser()
	}

	@objc func articleSearch(_ sender: Any?) {
		coordinator.showSearch()
	}

	@objc func addNewArticle(_ sender: Any?) {
		coordinator.showAddArticle()
	}

	@objc func cleanUp(_ sender: Any?) {
		coordinator.cleanUp()
	}

	@objc func toggleReadArticlesFilter(_ sender: Any?) {
		coordinator.toggleReadArticlesFilter()
	}

	@objc func sync(_ sender: Any?) {
		appDelegate.manualRefresh(errorHandler: ErrorHandler.present(self))
	}

	@objc func goToAllUnread(_ sender: Any?) {
		coordinator.selectAllUnreadFeed()
	}

	@objc func goToStarred(_ sender: Any?) {
		coordinator.selectStarredFeed()
	}

	@objc func goToArchive(_ sender: Any?) {
		coordinator.selectArchiveFeed()
	}

	@objc func goToAllArticles(_ sender: Any?) {
		coordinator.selectAllArticlesFeed()
	}

	@objc func goToSettings(_ sender: Any?) {
		coordinator.showSettings()
	}

	@objc func toggleRead(_ sender: Any?) {
		coordinator.toggleReadForCurrentArticle()
	}

	@objc func showOriginal(_ sender: Any?) {
		coordinator.showOriginalForCurrentArticle()
	}

	@objc func toggleStarred(_ sender: Any?) {
		coordinator.toggleStarredForCurrentArticle()
	}
}
