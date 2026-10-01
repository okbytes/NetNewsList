//
//  MainFeedCollectionViewController.swift
//  NetNewsWire-iOS
//
//  Created by Stuart Breckenridge on 23/06/2025.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import UIKit
import os
import RSCore
import RSTree
import Account
import ActivityLog
import Articles
import Images

private let reuseIdentifier = "FeedCell"

/// The sidebar: one group of fixed lists (Inbox, Starred, Archive, All).
final class MainFeedCollectionViewController: UICollectionViewController {
	@IBOutlet var addNewItemButton: UIBarButtonItem! {
		didSet {
			addNewItemButton.target = self
			addNewItemButton.action = #selector(MainFeedCollectionViewController.add(_:))
		}
	}

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "MainFeedCollectionViewController")

	private let keyboardManager = KeyboardManager(type: .sidebar)
	override var keyCommands: [UIKeyCommand]? {

		// If the first responder is the WKWebView (PreloadedWebView) we don't want to supply any keyboard
		// commands that the system is looking for by going up the responder chain. They will interfere with
		// the WKWebViews built in hardware keyboard shortcuts, specifically the up and down arrow keys.
		guard let current = UIResponder.currentFirstResponder, !(current is PreloadedWebView) else {
			return nil
		}

		return keyboardManager.keyCommands
	}

	override var canBecomeFirstResponder: Bool {
		return true
	}

	private let refreshProgressView = RefreshProgressView(frame: .zero)
	private var currentActivityButton: UIBarButtonItem?

	weak var coordinator: SceneCoordinator!

	/// On iPhone, this property is used to prevent the user from selecting a new list while the current list is being deselected.
	/// While `isAnimating` is `true`, `shouldSelectItemAt()` will not allow new selection.
	/// The value is set to `true` in `viewWillAppear(_:)` if a list is selected, and reset to `false` in
	/// `viewDidAppear(_:)` after a delay to allow the deselection animation to complete.
	private var isAnimating: Bool = false
	private var isToolbarConfigured: Bool = false

	// Serialized snapshot updates — see enqueueSidebarUpdate below.
	private var isApplyingSnapshot = false
	private var queuedSidebarUpdates = [QueuedSidebarUpdate]()

	// Write via applySnapshot/reconfigureItems. Read via currentSidebarSnapshot
	// and the lookup methods — in an apply completion if you need post-update state.
	private var dataSource: UICollectionViewDiffableDataSource<String, SidebarItemNode>!

	override func viewDidLoad() {
		super.viewDidLoad()
		registerForNotifications()
		configureCurrentActivityButton()
		configureCollectionView()
		configureDiffableDataSource()
		becomeFirstResponder()
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		coordinator?.sidebarDidLayout()
	}

	func configureCurrentActivityButton() {
		if #available(iOS 26, *) {
			// Toolbar button to open Current Activity. It lights up while activity is happening.
			let settingsButtonIndex = 0
			let button = UIBarButtonItem(image: Assets.Images.currentActivity, style: .plain, target: self, action: #selector(showCurrentActivity(_:)))
			button.accessibilityLabel = NSLocalizedString("Current Activity", comment: "Current Activity")
			toolbarItems?.insert(button, at: settingsButtonIndex + 1)
			currentActivityButton = button
			NotificationCenter.default.addObserver(self, selector: #selector(activityDidChange(_:)), name: .activityDidChange, object: nil)
			updateCurrentActivityButtonState()
		} else {
			// Tap progress view in the toolbar to open Current Activity.
			refreshProgressView.isUserInteractionEnabled = true
			refreshProgressView.accessibilityTraits = .button
			refreshProgressView.accessibilityHint = NSLocalizedString("Shows current activity", comment: "Current Activity accessibility hint")
			let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showCurrentActivity(_:)))
			refreshProgressView.addGestureRecognizer(tapGestureRecognizer)
		}
	}

	@objc func activityDidChange(_ note: Notification) {
		updateCurrentActivityButtonState()
	}

	func updateCurrentActivityButtonState() {
		let hasCurrentActivity = !ActivityLog.shared.runningActivities.isEmpty || !ActivityLog.shared.pendingActivities.isEmpty
		currentActivityButton?.tintColor = hasCurrentActivity ? Assets.Colors.primaryAccent : .label
	}

	override func viewWillAppear(_ animated: Bool) {
		Self.logger.debug("MainFeedCollectionViewController: viewWillAppear")
		navigationController?.isToolbarHidden = false
		configureToolbarWithProgressView()
		super.viewWillAppear(animated)

		if traitCollection.userInterfaceIdiom == .phone {
			self.navigationController?.navigationBar.prefersLargeTitles = true
			self.navigationItem.largeTitleDisplayMode = .always
			DispatchQueue.main.async {
				// Sizes the bar to large. Skip if a pushed VC (e.g. the timeline, which shares this bar
				// on iPhone) is now on top, or it would be forced large too.
				// <https://github.com/Ranchero-Software/NetNewsWire/issues/5141>
				guard self.navigationController?.topViewController === self else {
					return
				}
				self.navigationController?.navigationBar.sizeToFit()
			}

			/// On iPhone, we want to deselect the list when the user navigates
			/// back to the sidebar. To prevent the user from selecting a new list while
			/// the current list is being deselected, set `isAnimating` to true.
			///
			/// `shouldSelectItemAt()` will not allow selection when `isAnimating`
			/// is `true.`
			if collectionView.indexPathsForSelectedItems != nil {
				isAnimating = true
			}
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		self.deselectIfNeccessary()
	}

	func deselectIfNeccessary() {
		guard traitCollection.userInterfaceIdiom == .phone else {
			return
		}

		defer {
			self.isAnimating = false
		}

		// Rotating a Pro Max to landscape expands the split view — wait for the transition to settle.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5043>
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
			// Deselect only when the sidebar is full screen.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/4691>
			if self.coordinator.isRootSplitCollapsed, self.collectionView.indexPathsForSelectedItems?.first != nil {
				self.coordinator.selectSidebarItem(indexPath: nil, animations: [.select])
			}
		}
	}

	func registerForNotifications() {
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self], target: self, action: #selector(preferredContentSizeCategoryDidChange))
	}

	// MARK: - Collection View Configuration
	func configureCollectionView() {
		let cellLeadingOffset = 48.0
		let useSidebarAppearance = traitCollection.userInterfaceIdiom == .pad
		var config = UICollectionLayoutListConfiguration(appearance: useSidebarAppearance ? .sidebar : .insetGrouped)
		config.headerMode = .none

		config.itemSeparatorHandler = { (indexPath, sectionSeparatorConfiguration) in
			var configuration = sectionSeparatorConfiguration

			// Sidebar appearance: no separators
			if useSidebarAppearance {
				configuration.topSeparatorVisibility = .hidden
				configuration.bottomSeparatorVisibility = .hidden
				return configuration
			}

			// insetGrouped appearance: separators with proper insets
			configuration.bottomSeparatorVisibility = .hidden
			configuration.topSeparatorVisibility = indexPath.row == 0 ? .hidden : .visible
			configuration.topSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: cellLeadingOffset, bottom: 0, trailing: 0)
			return configuration
		}

		let layout = UICollectionViewCompositionalLayout.list(using: config)
		collectionView.setCollectionViewLayout(layout, animated: false)
		let refreshControl = UIRefreshControl()
		refreshControl.addTarget(self, action: #selector(sync(_:)), for: .valueChanged)
		collectionView.refreshControl = refreshControl

		if config.appearance == .sidebar {
			// This defrosts the glass.
			collectionView.backgroundColor = .clear
		} else {
			collectionView.backgroundColor = .systemGroupedBackground
		}
	}

	func configureDiffableDataSource() {
		dataSource = UICollectionViewDiffableDataSource<String, SidebarItemNode>(
			collectionView: collectionView
		) { [weak self] collectionView, indexPath, sidebarItemNode -> UICollectionViewCell? in
			guard let self else {
				return nil
			}
			let cell = collectionView.dequeueReusableCell(withReuseIdentifier: reuseIdentifier, for: indexPath)
			if let cell = cell as? MainFeedCollectionViewCell {
				self.configure(cell, sidebarItemNode: sidebarItemNode)
			}
			return cell
		}
	}

	func applySnapshot(_ snapshot: NSDiffableDataSourceSnapshot<String, SidebarItemNode>, animatingDifferences: Bool, completion: (() -> Void)? = nil) {
		enqueueSidebarUpdate(.full(snapshot, animated: animatingDifferences), completion: completion)
	}

	func reconfigureItems(_ items: [SidebarItemNode], completion: (() -> Void)? = nil) {
		enqueueSidebarUpdate(.reconfigure(items), completion: completion)
	}

	// MARK: - Data Source Queries

	var currentSidebarSnapshot: NSDiffableDataSourceSnapshot<String, SidebarItemNode> {
		dataSource.snapshot()
	}

	func sidebarItemNode(for indexPath: IndexPath) -> SidebarItemNode? {
		dataSource.itemIdentifier(for: indexPath)
	}

	func indexPath(for sidebarItemNode: SidebarItemNode) -> IndexPath? {
		dataSource.indexPath(for: sidebarItemNode)
	}

	// MARK: - Serialized Snapshot Updates

	// Overlapping animated dataSource.apply calls strand cells — a row mid-delete-animation
	// never gets recycled while the next update slides another row into its slot, leaving
	// two cells overlapping. Updates are queued and applied one at a time. The apply
	// completion is the animation-end signal, so serializing on it is sufficient.

	private func enqueueSidebarUpdate(_ update: SidebarUpdate, completion: (() -> Void)?) {
		var completions = [() -> Void]()
		if let completion {
			completions.append(completion)
		}

		// A newer full snapshot supersedes a queued one. The superseded update's
		// completions still run — after a snapshot at least as new as the one they requested.
		if update.isFull, let index = queuedSidebarUpdates.firstIndex(where: { $0.update.isFull }) {
			completions = queuedSidebarUpdates[index].completions + completions
			queuedSidebarUpdates.remove(at: index)
		}

		queuedSidebarUpdates.append(QueuedSidebarUpdate(update: update, completions: completions))
		applyNextSidebarUpdateIfPossible()
	}

	private func applyNextSidebarUpdateIfPossible() {
		guard !isApplyingSnapshot, !queuedSidebarUpdates.isEmpty else {
			return
		}

		let queuedUpdate = queuedSidebarUpdates.removeFirst()

		var snapshot: NSDiffableDataSourceSnapshot<String, SidebarItemNode>
		var animated = false

		switch queuedUpdate.update {
		case .full(let fullSnapshot, let fullAnimated):
			snapshot = fullSnapshot
			animated = fullAnimated
		case .reconfigure(let items):
			snapshot = dataSource.snapshot()
			let survivingItems = survivingItems(items, in: snapshot)
			guard !survivingItems.isEmpty else {
				finishSkippedSidebarUpdate(queuedUpdate)
				return
			}
			snapshot.reconfigureItems(survivingItems)
		case .reload(let items):
			snapshot = dataSource.snapshot()
			let survivingItems = survivingItems(items, in: snapshot)
			guard !survivingItems.isEmpty else {
				finishSkippedSidebarUpdate(queuedUpdate)
				return
			}
			snapshot.reloadItems(survivingItems)
		}

		// Animating a batch update while detached from a window strands cells too.
		let animatingDifferences = animated && viewIfLoaded?.window != nil

		isApplyingSnapshot = true
		dataSource.apply(snapshot, animatingDifferences: animatingDifferences) { [weak self] in
			guard let self else {
				return
			}
			// Completions run before the queue pumps again, so an update enqueued
			// synchronously by a completion applies after this one — in order.
			for completion in queuedUpdate.completions {
				completion()
			}
			self.isApplyingSnapshot = false
			self.applyNextSidebarUpdateIfPossible()
		}
	}

	// Reconfigures and reloads resolve their items at execution time, against the
	// currently applied snapshot. Items removed by an earlier queued update are
	// skipped — reloading an absent identifier throws.
	private func survivingItems(_ items: [SidebarItemNode], in snapshot: NSDiffableDataSourceSnapshot<String, SidebarItemNode>) -> [SidebarItemNode] {
		let currentItems = Set(snapshot.itemIdentifiers)
		return items.filter { currentItems.contains($0) }
	}

	private func finishSkippedSidebarUpdate(_ queuedUpdate: QueuedSidebarUpdate) {
		for completion in queuedUpdate.completions {
			completion()
		}
		applyNextSidebarUpdateIfPossible()
	}

	@IBAction func settings(_ sender: UIBarButtonItem) {
		coordinator.showSettings()
	}

	@objc func showCurrentActivity(_ sender: Any?) {
		coordinator.showCurrentActivity()
	}

	// MARK: UICollectionViewDelegate

	override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		becomeFirstResponder()
	}

	// Fires on every tap — even on the already-selected list, which doesn't get didSelectItemAt.
	override func collectionView(_ collectionView: UICollectionView, performPrimaryActionForItemAt indexPath: IndexPath) {
		becomeFirstResponder()
		coordinator.selectSidebarItem(indexPath: indexPath, animations: [.navigation, .select, .scroll])
	}

	override func collectionView(_ collectionView: UICollectionView, canPerformPrimaryActionForItemAt indexPath: IndexPath) -> Bool {
		if traitCollection.userInterfaceIdiom == .pad {
			return true
		}
		return !isAnimating
	}

	override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
		if traitCollection.userInterfaceIdiom == .pad {
			return true
		}
		return !isAnimating
	}

	override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		guard let archiveAllAction = archiveAllAction(indexPath: indexPath) else {
			return nil
		}
		return UIContextMenuConfiguration(identifier: MainFeedRowIdentifier(indexPath: indexPath), previewProvider: nil) { _ in
			UIMenu(title: "", children: [archiveAllAction])
		}
	}

	// MARK: - Keyboard shortcuts

	@objc func markAllAsRead(_ sender: Any) {
		guard let indexPath = collectionView.indexPathsForSelectedItems?.first, let contentView = collectionView.cellForItem(at: indexPath)?.contentView else {
			return
		}

		let title = NSLocalizedString("Archive All", comment: "Command")
		let articlesToMark = coordinator.articles

		MarkAsReadAlertController.confirm(self, coordinator: coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
			self?.coordinator.markAsReadAndShowSidebar(articlesToMark)
		}
	}

	@objc func navigateToTimeline(_ sender: Any?) {
		coordinator.navigateToTimeline()
	}

	@objc func selectNextDown(_ sender: Any?) {
		coordinator.selectNextFeed()
	}

	@objc func selectNextUp(_ sender: Any?) {
		coordinator.selectPrevFeed()
	}

	// MARK: - API

	func focus() {
		becomeFirstResponder()
	}

	func updateFeedSelection(animations: Animations) {
		if let indexPath = coordinator.currentFeedIndexPath {
			collectionView.selectItemAndScrollIfNotVisible(at: indexPath, animations: animations)
		} else {
			if let indexPath = collectionView.indexPathsForSelectedItems?.first {
				if animations.contains(.select) {
					collectionView.deselectItem(at: indexPath, animated: true)
				} else {
					collectionView.deselectItem(at: indexPath, animated: false)
				}
			}
		}
	}

	func configureIcon(_ cell: MainFeedCollectionViewCell, sidebarItem: SidebarItem) {
		guard let sidebarItemID = sidebarItem.sidebarItemID else {
			return
		}
		cell.iconImage = IconImageCache.shared.imageFor(sidebarItemID)
	}

	func restoreSelectionIfNecessary(adjustScroll: Bool) {
		if let indexPath = coordinator.mainFeedIndexPathForCurrentTimeline() {
			if adjustScroll {
				collectionView.selectItemAndScrollIfNotVisible(at: indexPath, animations: [])
			} else {
				collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
			}
		}
	}

	// MARK: - Private

	func configureToolbarWithProgressView() {
		if #available(iOS 26, *) {
			return
		}

		guard !isToolbarConfigured else {
			return
		}

		// Expect three items: left button, flex space, right button.
		let expectedItemCount = 3
		guard var items = toolbarItems, items.count == expectedItemCount else {
			return
		}

		// Replace the middle flex space with: flex, progress, flex
		// to center the progress view between the two buttons.
		let middleIndex = 1
		isToolbarConfigured = true
		let refreshBarItem = UIBarButtonItem(customView: refreshProgressView)
		items[middleIndex] = UIBarButtonItem.flexibleSpace()
		items.insert(refreshBarItem, at: middleIndex + 1)
		items.insert(UIBarButtonItem.flexibleSpace(), at: middleIndex + 2)
		toolbarItems = items
	}

	func configure(_ cell: MainFeedCollectionViewCell, sidebarItemNode: SidebarItemNode) {
		guard let sidebarItem = sidebarItemNode.node.representedObject as? SidebarItem else {
			return
		}
		cell.feedTitle.text = sidebarItem.nameForDisplay
		cell.unreadCount = sidebarItem.unreadCount
		configureIcon(cell, sidebarItem: sidebarItem)
	}

	private func reloadAllVisibleCells() {
		let visibleIndexPaths = collectionView.indexPathsForVisibleItems
		let itemIdentifiers = visibleIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
		reloadCells(itemIdentifiers) { [weak self] in
			self?.restoreSelectionIfNecessary(adjustScroll: false)
		}
	}

	private func reloadCells(_ items: [SidebarItemNode], completion: (() -> Void)? = nil) {
		guard !items.isEmpty else {
			completion?()
			return
		}

		enqueueSidebarUpdate(.reload(items), completion: completion)
	}

	// MARK: - Notifications

	@objc func preferredContentSizeCategoryDidChange() {
		IconImageCache.shared.emptyCache()
		reloadAllVisibleCells()
	}

	@objc func unreadCountDidChange(_ note: Notification) {
		guard let unreadCountProvider = note.object as? UnreadCountProvider else {
			return
		}

		// Reconfigure through the serialized funnel — mutating visible cells directly
		// can change their size in the middle of an animated snapshot apply.
		let nodesToReconfigure = dataSource.snapshot().itemIdentifiers.filter {
			$0.node.representedObject === unreadCountProvider as AnyObject
		}
		guard !nodesToReconfigure.isEmpty else {
			return
		}
		reconfigureItems(nodesToReconfigure)
	}

	// MARK: - Actions

	@objc func sync(_ sender: Any) {
		collectionView.refreshControl?.endRefreshing()

		// This is a hack to make sure that an error dialog doesn't interfere with dismissing the refreshControl.
		// If the error dialog appears too closely to the call to endRefreshing, then the refreshControl never disappears.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			appDelegate.manualRefresh(errorHandler: ErrorHandler.present(self))
		}
	}

	@IBAction func add(_ sender: UIBarButtonItem) {
		coordinator.showAddArticle()
	}
}

// MARK: - Context Menu

private extension MainFeedCollectionViewController {

	func archiveAllAction(indexPath: IndexPath) -> UIAction? {
		guard let sidebarItem = dataSource.itemIdentifier(for: indexPath)?.node.representedObject as? SidebarItem,
			  let contentView = collectionView.cellForItem(at: indexPath)?.contentView,
			  sidebarItem.unreadCount > 0 else {
			return nil
		}

		let title = NSLocalizedString("Archive All", comment: "Command")
		return UIAction(title: title, image: Assets.Images.markAllAsRead) { [weak self] _ in
			MarkAsReadAlertController.confirm(self, coordinator: self?.coordinator, confirmTitle: title, sourceType: contentView) { [weak self] in
				let articles = sidebarItem.fetchUnreadArticles()
				self?.coordinator.markAllAsRead(Array(articles))
			}
		}
	}
}

// MARK: - SidebarUpdate

private enum SidebarUpdate {
	case full(NSDiffableDataSourceSnapshot<String, SidebarItemNode>, animated: Bool)
	case reconfigure([SidebarItemNode])
	case reload([SidebarItemNode])

	var isFull: Bool {
		if case .full = self {
			return true
		}
		return false
	}
}

private struct QueuedSidebarUpdate {
	let update: SidebarUpdate
	let completions: [() -> Void]
}
