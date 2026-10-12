//
//  TimelineContainerViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/14/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import AppKit
import Account
import Articles

@MainActor protocol TimelineContainerViewControllerDelegate: AnyObject {
	func timelineSelectionDidChange(_: TimelineContainerViewController, articles: [Article]?)
	func timelineInvalidatedRestorationState(_: TimelineContainerViewController)
}

final class TimelineContainerViewController: NSViewController {

	@IBOutlet var viewOptionsPopUpButton: NSPopUpButton!
	@IBOutlet var headerSeparator: NSBox!
	@IBOutlet var containerViewTopToHeaderConstraint: NSLayoutConstraint!
	@IBOutlet var containerView: TimelineContainerView!

	private var layout = AppDefaults.shared.timelineLayout {
		didSet {
			if layout != oldValue {
				layoutDidChange()
			}
		}
	}
	// Column layout hides the sort header, and this pins the timeline to the top instead.
	private lazy var containerViewTopToViewConstraint = containerView.topAnchor.constraint(equalTo: view.topAnchor)

	var windowState: TimelineWindowState {
		timelineViewController.windowState
	}

	/// This window’s sort.
	private(set) var sortParameters = TimelineContainerViewController.seedSortParameters {
		didSet {
			if sortParameters == oldValue {
				return
			}
			timelineViewController.sortParameters = sortParameters
			updateViewOptionsPopUpButton()
			delegate?.timelineInvalidatedRestorationState(self)
		}
	}

	weak var delegate: TimelineContainerViewControllerDelegate?

	lazy var timelineViewController = {
		let viewController = TimelineViewController(delegate: self)
		viewController.sortParameters = sortParameters
		viewController.layout = layout
		return viewController
	}()

	convenience init() {
		self.init(nibName: "TimelineContainerView", bundle: nil)
	}

    override func viewDidLoad() {
        super.viewDidLoad()
		containerView.contentView = timelineViewController.view

		// The first item is the pop-up’s hidden title.
		for menuItem in viewOptionsPopUpButton.itemArray.dropFirst() where !menuItem.isSeparatorItem {
			makeMenuItemTitleLarger(menuItem)
		}
		updateViewOptionsPopUpButton()
		updateHeaderVisibility()

		NotificationCenter.default.addObserver(self, selector: #selector(handleUserDefaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)
    }

	// MARK: - Notifications

	@objc nonisolated func handleUserDefaultsDidChange(_ note: Notification) {
		Task { @MainActor in
			self.userDefaultsDidChange()
		}
	}

	private func userDefaultsDidChange() {
		layout = AppDefaults.shared.timelineLayout
	}

	// MARK: - API

	/// Choosing the current field keeps its direction. Choosing another starts with that field’s natural direction.
	func sortBy(key: ArticleSortKey) {
		if key == sortParameters.key {
			return
		}
		sortParameters = sortParameters.withKey(key, direction: key.firstDirection)
	}

	func setSortDirection(_ direction: ComparisonResult) {
		sortParameters = sortParameters.withDirection(direction)
	}

	func setRepresentedObjects(_ objects: [AnyObject]?) {
		timelineViewController.representedObjects = objects
	}

	// MARK: State Restoration

	func restoreState(from state: TimelineWindowState?) {
		guard let state else { return }

		// Sort first so the restored selection lands in the right row.
		if let savedSortParameters = state.sortParameters {
			sortParameters = savedSortParameters
		}
		timelineViewController.restoreState(from: state)
	}

	/// Restore state using legacy state restoration data.
	///
	/// TODO: Delete for NetNewsWire 7.
	func restoreLegacyState(from state: [AnyHashable: Any]) {
		timelineViewController.restoreLegacyState(from: state)
	}
}

extension TimelineContainerViewController: TimelineDelegate {

	func timelineSelectionDidChange(_ timelineViewController: TimelineViewController, selectedArticles: [Article]?) {
		delegate?.timelineSelectionDidChange(self, articles: selectedArticles)
	}

	func timelineInvalidatedRestorationState(_: TimelineViewController) {
		delegate?.timelineInvalidatedRestorationState(self)
	}

	func timelineRequestedSortChange(_: TimelineViewController, parameters: ArticleSortParameters) {
		sortParameters = parameters
	}
}

private extension TimelineContainerViewController {

	func makeMenuItemTitleLarger(_ menuItem: NSMenuItem) {
		menuItem.attributedTitle = NSAttributedString(string: menuItem.title,
													  attributes: [NSAttributedString.Key.font: NSFont.controlContentFont(ofSize: NSFont.systemFontSize)])
	}

	// The pop-up’s items share the View menu’s actions, so their checkmarks and direction titles come from
	// MainWindowController’s validation. Only the button title is set here.
	func updateViewOptionsPopUpButton() {
		guard isViewLoaded else {
			return
		}
		viewOptionsPopUpButton.setTitle(sortParameters.key.localizedName)
	}

	/// For a window with no saved sort. Group By Feed, from before sorting was per window, became sorting by feed.
	static var seedSortParameters: ArticleSortParameters {
		if AppDefaults.shared.timelineGroupByFeed {
			return ArticleSortParameters(key: .feed, direction: .orderedAscending)
		}
		return ArticleSortParameters(key: .date, direction: AppDefaults.shared.timelineSortDirection)
	}

	func layoutDidChange() {
		timelineViewController.layout = layout
		updateHeaderVisibility()
	}

	func updateHeaderVisibility() {
		let isHeaderHidden = layout == .column
		viewOptionsPopUpButton.isHidden = isHeaderHidden
		headerSeparator.isHidden = isHeaderHidden
		containerViewTopToHeaderConstraint.isActive = !isHeaderHidden
		containerViewTopToViewConstraint.isActive = isHeaderHidden
	}
}
