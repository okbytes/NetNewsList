//
//  NavigationModelController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/21/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import os
import UserNotifications
import Account
import Articles
import RSCore
import RSTree
import SafariServices
import SwiftUI
import Images

enum SearchScope: Int {
	case timeline = 0
	case global = 1
}

enum ShowFeedName {
	case none
	case byline
	case feed
}

struct SidebarItemNode: Hashable, Sendable {
	let node: Node
	let sidebarItemID: SidebarItemIdentifier

	@MainActor init(_ node: Node) {
		self.node = node
		self.sidebarItemID = (node.representedObject as! SidebarItem).sidebarItemID!
	}

	nonisolated func hash(into hasher: inout Hasher) {
		hasher.combine(sidebarItemID)
	}

	nonisolated static func == (lhs: SidebarItemNode, rhs: SidebarItemNode) -> Bool {
		lhs.sidebarItemID == rhs.sidebarItemID
	}
}

@MainActor final class SceneCoordinator: NSObject, UndoableCommandRunner {
	var undoableCommands = [UndoableCommand]()
	var undoManager: UndoManager? {
		return rootSplitViewController.undoManager
	}

	lazy var webViewProvider = WebViewProvider(coordinator: self)

	private var activityManager = ActivityManager()

	private var rootSplitViewController: RootSplitViewController!

	private var mainFeedCollectionViewController: MainFeedCollectionViewController!
	private var mainTimelineViewController: MainTimelineModernViewController?
	private var articleViewController: ArticleViewController?

	private let fetchAndMergeArticlesQueue = CoalescingQueue(name: "Fetch and Merge Articles", interval: 0.5)
	private let saveColumnWidthsQueue = CoalescingQueue(name: "Save Column Widths", interval: 0.5)
	private var fetchSerialNumber = 0
	private let fetchRequestQueue = FetchRequestQueue()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "SceneCoordinator")

	private let hidingReadArticlesState = HidingReadArticlesState()

	private(set) var preSearchTimelineFeed: SidebarItem?
	private var lastSearchString = ""
	private var lastSearchScope: SearchScope?
	private var isSearching: Bool = false
	private var savedSearchArticles: ArticleArray?
	private var savedSearchArticleIDs: Set<String>?
	private var isRestoringState = false

	var isTimelineViewControllerPending = false
	var isArticleViewControllerPending = false

	/// `Bool` to track whether a refresh is scheduled.
	private var isNavigationBarSubtitleRefreshScheduled: Bool = false

	private(set) var sortDirection = AppDefaults.shared.timelineSortDirection {
		didSet {
			if sortDirection != oldValue {
				sortParametersDidChange()
			}
		}
	}

	private(set) var groupByFeed = AppDefaults.shared.timelineGroupByFeed {
		didSet {
			if groupByFeed != oldValue {
				sortParametersDidChange()
			}
		}
	}

	var prefersStatusBarHidden = false

	private let treeControllerDelegate = SidebarTreeControllerDelegate()
	private let treeController: TreeController

	var stateRestorationActivity: NSUserActivity {
		activityManager.stateRestorationActivity
	}

	var isNavigationDisabled = false

	var isRootSplitCollapsed: Bool {
		return rootSplitViewController.isCollapsed
	}

	// In collapsed mode, the article view is in the window only while it's on top of the navigation stack.
	var isArticleViewControllerShowing: Bool {
		articleViewController?.viewIfLoaded?.window != nil
	}

	var isReadArticlesFiltered: Bool {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return false
		}
		return hidingReadArticlesState.isHidingReadArticles(for: sidebarItemID)
	}

	var timelineDefaultReadFilterType: ReadFilterType {
		return timelineFeed?.defaultReadFilterType ?? .none
	}

	var rootNode: Node {
		return treeController.rootNode
	}

	// At some point we should refactor the current Feed IndexPath out and only use the timeline feed
	private(set) var currentFeedIndexPath: IndexPath?

	var timelineIconImage: IconImage? {
		guard let timelineFeed = timelineFeed else {
			return nil
		}
		return IconImageCache.shared.imageForFeed(timelineFeed)
	}

	private var exceptionArticleFetcher: ArticleFetcher?
	private(set) var timelineFeed: SidebarItem? {
		didSet {
			mainTimelineViewController?.updateNavigationBarTitle(timelineFeed?.nameForDisplay ?? "")
			updateNavigationBarSubtitles(nil)
		}
	}

	var timelineMiddleIndexPath: IndexPath?

	// Every list mixes articles from many sites, so each row shows its site and icon.
	let showFeedNames = ShowFeedName.feed
	let showIcons = true

	// The sidebar is one section of lists.
	var prevFeedIndexPath: IndexPath? {
		guard let indexPath = currentFeedIndexPath, indexPath.row > 0 else {
			return nil
		}
		return IndexPath(row: indexPath.row - 1, section: indexPath.section)
	}

	var nextFeedIndexPath: IndexPath? {
		guard let indexPath = currentFeedIndexPath else {
			return nil
		}
		let snapshot = mainFeedCollectionViewController.currentSidebarSnapshot
		guard indexPath.section < snapshot.numberOfSections,
			  indexPath.row + 1 < snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[indexPath.section]) else {
			return nil
		}
		return IndexPath(row: indexPath.row + 1, section: indexPath.section)
	}

	var isPrevArticleAvailable: Bool {
		guard let articleRow = currentArticleRow else {
			return false
		}
		return articleRow > 0
	}

	var isNextArticleAvailable: Bool {
		guard let articleRow = currentArticleRow else {
			return false
		}
		return articleRow + 1 < articles.count
	}

	var prevArticle: Article? {
		guard isPrevArticleAvailable, let articleRow = currentArticleRow else {
			return nil
		}
		return articles[articleRow - 1]
	}

	var nextArticle: Article? {
		guard isNextArticleAvailable, let articleRow = currentArticleRow else {
			return nil
		}
		return articles[articleRow + 1]
	}

	var firstUnreadArticleIndexPath: IndexPath? {
		for (row, article) in articles.enumerated() {
			if !article.status.read {
				return IndexPath(row: row, section: 0)
			}
		}
		return nil
	}

	var currentArticle: Article? {
		didSet {
			if let article = currentArticle {
				AppDefaults.shared.selectedArticle = ArticleSpecifier(article: article)
			} else {
				AppDefaults.shared.selectedArticle = nil
			}
		}
	}

	private(set) var articles = ArticleArray() {
		didSet {
			timelineMiddleIndexPath = nil
			articleDictionaryNeedsUpdate = true
		}
	}

	private var articleDictionaryNeedsUpdate = true
	private var _idToArticleDictionary = [String: Article]()
	private var idToArticleDictionary: [String: Article] {
		if articleDictionaryNeedsUpdate {
			rebuildArticleDictionaries()
		}
		return _idToArticleDictionary
	}

	private var currentArticleRow: Int? {
		guard let article = currentArticle else {
			return nil
		}
		return articles.firstIndex(of: article)
	}

	var isTimelineUnreadAvailable: Bool {
		return timelineUnreadCount > 0
	}

	var isNextUnreadAvailable: Bool {
		// Return false when the only unread article is the selected article.
		// With nothing selected — e.g. the collapsed timeline — this falls through to "is there any unread at all".
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5008>
		if AccountManager.shared.unreadCount == 1, let article = currentArticle, !article.status.read {
			return false
		}
		return AccountManager.shared.unreadCount > 0
	}

	var timelineUnreadCount: Int = 0 {
		didSet {
			updateNavigationBarSubtitles(nil)
		}
	}

	private static let minimumTimelineWidth: CGFloat = 280
	private static let maximumTimelineWidth: CGFloat = 440

	private static func clampTimelineWidth(_ width: CGFloat) -> CGFloat {
		if width < minimumTimelineWidth {
			return minimumTimelineWidth
		}
		if width > maximumTimelineWidth {
			return maximumTimelineWidth
		}
		return width
	}

	private static let minimumSidebarWidth: CGFloat = 300
	private static let maximumSidebarWidth: CGFloat = 500

	private static func clampSidebarWidth(_ width: CGFloat) -> CGFloat {
		if width < minimumSidebarWidth {
			return minimumSidebarWidth
		}
		if width > maximumSidebarWidth {
			return maximumSidebarWidth
		}
		return width
	}

	init(rootSplitViewController: RootSplitViewController) {
		self.rootSplitViewController = rootSplitViewController
		self.rootSplitViewController.minimumPrimaryColumnWidth = SceneCoordinator.minimumSidebarWidth
		self.rootSplitViewController.maximumPrimaryColumnWidth = SceneCoordinator.maximumSidebarWidth
		self.rootSplitViewController.minimumSupplementaryColumnWidth = SceneCoordinator.minimumTimelineWidth
		self.rootSplitViewController.maximumSupplementaryColumnWidth = SceneCoordinator.maximumTimelineWidth
		let restoredTimelineWidth: CGFloat
		if let savedTimelineWidth = AppDefaults.shared.timelineWidth {
			restoredTimelineWidth = CGFloat(savedTimelineWidth)
		} else {
			restoredTimelineWidth = 320
		}
		self.rootSplitViewController.preferredSupplementaryColumnWidth = Self.clampTimelineWidth(restoredTimelineWidth)
		if let savedSidebarWidth = AppDefaults.shared.sidebarWidth {
			self.rootSplitViewController.preferredPrimaryColumnWidth = Self.clampSidebarWidth(CGFloat(savedSidebarWidth))
		}
		self.rootSplitViewController.preferredSplitBehavior = .tile

		self.treeController = TreeController(delegate: treeControllerDelegate)

		super.init()

		self.mainFeedCollectionViewController = rootSplitViewController.viewController(for: .primary) as? MainFeedCollectionViewController
		self.mainFeedCollectionViewController.coordinator = self
		self.mainFeedCollectionViewController?.navigationController?.delegate = self
		updateNavigationBarSubtitles(nil)

		self.mainTimelineViewController = rootSplitViewController.viewController(for: .supplementary) as? MainTimelineModernViewController
		self.mainTimelineViewController?.coordinator = self
		self.mainTimelineViewController?.navigationController?.delegate = self

		self.articleViewController = rootSplitViewController.viewController(for: .secondary) as? ArticleViewController
		self.articleViewController?.coordinator = self
		self.articleViewController?.navigationController?.delegate = self

		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(containerChildrenDidChange(_:)), name: .ChildrenDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountStateDidChange(_:)), name: .AccountStateDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDeleteArticles(_:)), name: .AccountDidDeleteArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(importDownloadedTheme(_:)), name: .didEndDownloadingTheme, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(themeDownloadDidFail(_:)), name: .didFailToImportThemeWithError, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(updateNavigationBarSubtitles(_:)), name: .progressInfoDidChange, object: CombinedRefreshProgress.shared)

		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}
	}

	func restoreWindowState(restoreSelection: Bool) {
		Self.logger.debug("SceneCoordinator: restoreWindowState")

		let stateInfo = StateRestorationInfo()
		isRestoringState = true

		hidingReadArticlesState.copy(from: stateInfo)

		// Ensure the view is loaded so dataSource is initialized before rebuilding
		_ = mainFeedCollectionViewController.view

		rebuildBackingStores(initialLoad: true)

		guard restoreSelection else {
			isRestoringState = false
			return
		}

		restoreSelectedSidebarItemAndArticle(stateInfo)
	}

	private func restoreSelectedSidebarItemAndArticle(_ stateInfo: StateRestorationInfo) {
		guard let selectedSidebarItem = stateInfo.selectedSidebarItem else {
			isRestoringState = false
			return
		}

		guard let sidebarItemNode = nodeFor(sidebarItemID: selectedSidebarItem),
			  let indexPath = indexPathFor(sidebarItemNode) else {
			isRestoringState = false
			return
		}
		selectSidebarItem(indexPath: indexPath, animations: []) {
			self.restoreSelectedArticle(stateInfo)
		}
	}

	private func restoreSelectedArticle(_ stateInfo: StateRestorationInfo) {
		defer {
			isRestoringState = false
		}

		guard let articleSpecifier = stateInfo.selectedArticle else {
			return
		}

		let article = articles.article(matching: articleSpecifier) ??
		AccountManager.shared.fetchArticle(accountID: articleSpecifier.accountID,
										   articleID: articleSpecifier.articleID)

		if let article {
			// Disable animation since this function runs only during state restoration on launch.
			UIView.performWithoutAnimation {
				selectArticle(article, articleWindowScrollY: stateInfo.articleWindowScrollY)
			}
		}
	}

	func handle(_ activity: NSUserActivity) {
		guard let activityType = ActivityType(rawValue: activity.activityType) else {
			return
		}

		// Add Feed just presents a sheet — unlike the activities below, it doesn't navigate,
		// so it must not clear the current selection.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4352>
		if activityType == .addFeedIntent {
			showAddArticle()
			return
		}

		selectSidebarItem(indexPath: nil) {
			switch activityType {
			case .selectFeed:
				self.handleSelectFeed(activity.userInfo)
			case .nextUnread:
				self.selectFirstUnreadInAllUnread()
			case .readArticle:
				self.handleReadArticle(activity.userInfo)
			case .restoration, .addFeedIntent:
				break
			}
		}
	}

	func handle(_ response: UNNotificationResponse) {
		let userInfo = response.notification.request.content.userInfo
		handleReadArticle(userInfo)
	}

	func resetFocus() {
		if currentArticle != nil {
			mainTimelineViewController?.focus()
		} else {
			mainFeedCollectionViewController?.focus()
		}
	}

	func selectFirstUnreadInAllUnread() {
		selectListWhenSidebarIsReady(SmartFeedsController.shared.unreadFeed, animations: []) {
			self.selectFirstUnreadArticleInTimeline()
		}
	}

	func showSearch() {
		selectSidebarItem(indexPath: nil) {
			self.rootSplitViewController.showColumn(.supplementary)
			DispatchQueue.main.asyncAfter(deadline: .now()) {
				self.mainTimelineViewController!.showSearchAll()
			}
		}
	}

	// MARK: Notifications

	@objc func statusesDidChange(_ note: Notification) {
		updateUnreadCount()
	}

	// Every list draws on the Reading List feed, so any change to the account's
	// feeds or articles refreshes the timeline.

	@objc func containerChildrenDidChange(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: containerChildrenDidChange")
		fetchAndMergeArticlesAsync(animated: true) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
		}
	}

	@objc func accountStateDidChange(_ note: Notification) {
		Self.logger.debug("SceneCoordinator: accountStateDidChange")
		fetchAndMergeArticlesAsync(animated: true) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
		}
	}

	func userDefaultsDidChange() {
		sortDirection = AppDefaults.shared.timelineSortDirection
		groupByFeed = AppDefaults.shared.timelineGroupByFeed
	}

	@objc func accountDidDownloadArticles(_ note: Notification) {
		queueFetchAndMergeArticles()
	}

	/// Deleted articles leave the timeline at once. A fetch-and-merge would keep them.
	@objc func accountDidDeleteArticles(_ note: Notification) {
		guard let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>,
			  articles.contains(where: { articleIDs.contains($0.articleID) }) else {
			return
		}
		if let currentArticle, articleIDs.contains(currentArticle.articleID) {
			selectArticle(nil)
		}
		replaceArticles(with: articles.filter { !articleIDs.contains($0.articleID) }, animated: true)
	}

	@objc func willEnterForeground(_ note: Notification) {
		// Don't interfere with any fetch requests that we may have initiated before the app was returned to the foreground.
		// For example if you select Next Unread from the Home Screen Quick actions, you can start a request before we are
		// in the foreground.
		if !fetchRequestQueue.isAnyCurrentRequest {
			queueFetchAndMergeArticles()
		}
		AccountManager.shared.repairStatusesIfNeeded()
	}

	@objc func importDownloadedTheme(_ note: Notification) {
		guard let userInfo = note.userInfo,
			let url = userInfo["url"] as? URL else {
			return
		}

		DispatchQueue.main.async {
			self.importTheme(filename: url.path)
		}
	}

	@objc func themeDownloadDidFail(_ note: Notification) {
		guard let userInfo = note.userInfo,
			  let error = userInfo["error"] as? Error else {
				  return
			  }
		DispatchQueue.main.async {
			let title = NSLocalizedString("Theme Error", comment: "Theme download error")
			self.rootSplitViewController.presentError(title: title, message: ArticleThemesManager.importErrorMessage(for: error))
		}
	}

	/// Updates navigation bar subtitles in response to feed selection, unread count changes,
	/// `progressInfoDidChange` notifications, and a timed refresh every
	/// 60s.
	///
	/// Subtitles are handled differently on iPhone and iPad.
	///
	/// `MainFeedViewController`
	/// - When refreshing: Feeds will display "Updating..." on both iPhone and iPad.
	/// - When refreshed: Feeds will display "Updated <#relative_time#>" on both iPhone and iPad.
	///
	/// `MainTimelineViewController`
	/// - Where the unread count for the timeline is > 0, this is displayed on both iPhone and iPad.
	/// - If the timeline count is 0, the iPhone follows the same logic as `MainFeedViewController`
	/// - Specific to iPad, if the unread count is 0, the iPad will not display a subtitle. The refresh text
	/// will generally be visible in the sidebar and there's no need to display it twice.
	///
	/// - Parameter note: Optional `Notification`
	@objc func updateNavigationBarSubtitles(_ note: Notification?) {
		let progressInfo = CombinedRefreshProgress.shared.progressInfo

		if progressInfo.isComplete {
			if let accountLastArticleFetchEndTime = AccountManager.shared.lastRefreshCompletedDate {
				if Date.now > accountLastArticleFetchEndTime.addingTimeInterval(60) {
					let relativeDateTimeFormatter = RelativeDateTimeFormatter()
					relativeDateTimeFormatter.dateTimeStyle = .named
					let refreshed = relativeDateTimeFormatter.localizedString(for: accountLastArticleFetchEndTime, relativeTo: Date())
					let localizedRefreshText = NSLocalizedString("Updated %@", comment: "Updated")
					let refreshText = NSString.localizedStringWithFormat(localizedRefreshText as NSString, refreshed) as String

					// Update Feeds with Updated text
					if #available(iOS 26, *) {
						self.mainFeedCollectionViewController?.navigationItem.subtitle = refreshText
					}

					// If unread count > 0, add unread string to timeline
					if timelineFeed != nil, timelineUnreadCount > 0 {
						let localizedUnreadCount = NSLocalizedString("%i Unread", comment: "14 Unread")
						let unreadCount = NSString.localizedStringWithFormat(localizedUnreadCount as NSString, timelineUnreadCount) as String
						self.mainTimelineViewController?.updateNavigationBarSubtitle(unreadCount)
					} else {
						// When unread count == 0, iPhone timeline displays Updated Just Now; iPad is blank
						if UIDevice.current.userInterfaceIdiom == .phone {
							self.mainTimelineViewController?.updateNavigationBarSubtitle(refreshText)
						} else {
							self.mainTimelineViewController?.updateNavigationBarSubtitle("")
						}
					}
				} else {
					// Use 'Updated Just Now' while <60s have passed since refresh.
					if #available(iOS 26, *) {
						self.mainFeedCollectionViewController?.navigationItem.subtitle = NSLocalizedString("Updated Just Now", comment: "Updated Just Now")
					}

					// If unread count > 0, add unread string to timeline
					if timelineFeed != nil, timelineUnreadCount > 0 {
						let localizedUnreadCount = NSLocalizedString("%i Unread", comment: "14 Unread")
						let refreshTextWithUnreadCount = NSString.localizedStringWithFormat(localizedUnreadCount as NSString, timelineUnreadCount) as String
						self.mainTimelineViewController?.updateNavigationBarSubtitle(refreshTextWithUnreadCount)
					} else {
						// When unread count == 0, iPhone timeline displays Updated Just Now; iPad is blank
						if UIDevice.current.userInterfaceIdiom == .phone {
							self.mainTimelineViewController?.updateNavigationBarSubtitle(NSLocalizedString("Updated Just Now", comment: "Updated Just Now"))
						} else {
							self.mainTimelineViewController?.updateNavigationBarSubtitle("")
						}
					}
				}
			} else {
				if #available(iOS 26, *) {
					self.mainFeedCollectionViewController?.navigationItem.subtitle = ""
				}
				// If unread count > 0, add unread string to timeline
				if timelineFeed != nil, timelineUnreadCount > 0 {
					let localizedUnreadCount = NSLocalizedString("%i Unread", comment: "14 Unread")
					let refreshTextWithUnreadCount = NSString.localizedStringWithFormat(localizedUnreadCount as NSString, timelineUnreadCount) as String
					self.mainTimelineViewController?.updateNavigationBarSubtitle(refreshTextWithUnreadCount)
				} else {
					// When unread count == 0, iPhone timeline displays Updated Just Now; iPad is blank
					if UIDevice.current.userInterfaceIdiom == .phone {
						self.mainTimelineViewController?.updateNavigationBarSubtitle(NSLocalizedString("Updated Just Now", comment: "Updated Just Now"))
					} else {
						self.mainTimelineViewController?.updateNavigationBarSubtitle("")
					}
				}
			}
		} else {
			// Updating in progress, apply to both iPhone and iPad Feeds.
			if #available(iOS 26, *) {
				self.mainFeedCollectionViewController?.navigationItem.subtitle = NSLocalizedString("Updating…", comment: "Updating…")
			}
		}

		scheduleNavigationBarSubtitleUpdate()
	}

	func scheduleNavigationBarSubtitleUpdate() {
		if isNavigationBarSubtitleRefreshScheduled {
			return
		}
		isNavigationBarSubtitleRefreshScheduled = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
			self?.isNavigationBarSubtitleRefreshScheduled = false
			self?.updateNavigationBarSubtitles(nil)
		}
	}

	// MARK: API

	func didEnterBackground() {
		hidingReadArticlesState.save()
	}

	func timelineDidLayout() {
		saveColumnWidthsQueue.add(self, #selector(saveTimelineWidth))
	}

	@objc private func saveTimelineWidth() {
		guard !rootSplitViewController.isCollapsed, rootSplitViewController.displayMode != .secondaryOnly else {
			return
		}
		// The timeline view extends under the sidebar, so its bounds are wider than the column looks.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5401>
		let width = mainTimelineViewController?.view.safeAreaLayoutGuide.layoutFrame.width ?? 0
		guard width > 0 else {
			return
		}
		AppDefaults.shared.timelineWidth = Int(SceneCoordinator.clampTimelineWidth(width))
	}

	func sidebarDidLayout() {
		saveColumnWidthsQueue.add(self, #selector(saveSidebarWidth))
	}

	@objc private func saveSidebarWidth() {
		// The sidebar is only on screen in the "two" display modes. In the others, a layout pass
		// during a hide animation could measure a transient width that the clamp would floor to the minimum.
		let displayMode = rootSplitViewController.displayMode
		let sidebarIsVisible = displayMode == .twoBesideSecondary || displayMode == .twoOverSecondary || displayMode == .twoDisplaceSecondary
		guard !rootSplitViewController.isCollapsed, sidebarIsVisible else {
			return
		}
		let width = mainFeedCollectionViewController?.view.safeAreaLayoutGuide.layoutFrame.width ?? 0
		guard width > 0 else {
			return
		}
		AppDefaults.shared.sidebarWidth = Int(SceneCoordinator.clampSidebarWidth(width))
	}

	func suspend() {
		fetchAndMergeArticlesQueue.performCallsImmediately()
		fetchRequestQueue.cancelAllRequests()
	}

	func cleanUp() {
		Self.logger.debug("SceneCoordinator: cleanUp")
		if isReadArticlesFiltered {
			refreshTimeline(resetScroll: false)
		}
	}

	func shouldShowFilterButton() -> Bool {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return false
		}
		return hidingReadArticlesState.canToggleHidingReadArticles(for: sidebarItemID)
	}

	func toggleReadArticlesFilter() {
		guard let sidebarItemID = timelineFeed?.sidebarItemID else {
			return
		}
		hidingReadArticlesState.toggleHidingReadArticles(for: sidebarItemID)
		refreshTimeline(resetScroll: false)
	}

	func nodeFor(sidebarItemID: SidebarItemIdentifier) -> Node? {
		return treeController.rootNode.descendantNode(where: { node in
			if let sidebarItem = node.representedObject as? SidebarItem {
				return sidebarItem.sidebarItemID == sidebarItemID
			} else {
				return false
			}
		})
	}

	func nodeFor(_ indexPath: IndexPath) -> Node? {
		guard let sidebarItemNode = mainFeedCollectionViewController.sidebarItemNode(for: indexPath) else {
			return nil
		}
		return sidebarItemNode.node
	}

	func indexPathFor(_ node: Node) -> IndexPath? {
		let sidebarItemNode = SidebarItemNode(node)
		return mainFeedCollectionViewController.indexPath(for: sidebarItemNode)
	}

	func articleFor(_ articleID: String) -> Article? {
		// Check if it's the currently displayed article
		if let currentArticle, currentArticle.articleID == articleID {
			return currentArticle
		}
		return idToArticleDictionary[articleID]
	}

	func refreshTimeline(resetScroll: Bool) {
		if let article = self.currentArticle, let account = article.account {
			exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: article.articleID)
		}
		fetchAndReplaceArticlesAsync(animated: true, emptyFirst: false) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: resetScroll)
		}
	}

	func mainFeedIndexPathForCurrentTimeline() -> IndexPath? {
		guard let node = treeController.rootNode.descendantNodeRepresentingObject(timelineFeed as AnyObject) else {
			return nil
		}
		return indexPathFor(node)
	}

	func selectFeed(_ sidebarItem: SidebarItem?, animations: Animations = [], deselectArticle: Bool = true, completion: (() -> Void)? = nil) {
		let indexPath: IndexPath? = {
			if let sidebarItem, let indexPath = indexPathFor(sidebarItem as AnyObject) {
				return indexPath
			} else {
				return nil
			}
		}()
		selectSidebarItem(indexPath: indexPath, animations: animations, deselectArticle: deselectArticle, completion: completion)
		updateNavigationBarSubtitles(nil)
	}

	func selectSidebarItem(indexPath: IndexPath?, animations: Animations = [], deselectArticle: Bool = true, completion: (() -> Void)? = nil) {
		Self.logger.debug("SceneCoordinator: selectSidebarItem")

		// Compare by feed identity, not indexPath — indexPath can change when feeds are added/removed
		var tappedFeed: AnyObject?
		if let indexPath {
			tappedFeed = nodeFor(indexPath)?.representedObject as AnyObject?
		}
		guard tappedFeed !== timelineFeed as AnyObject? else {
			// Same feed — just make sure the timeline is showing.
			if indexPath != nil {
				rootSplitViewController.showColumn(.supplementary)
			}
			completion?()
			return
		}

		currentFeedIndexPath = indexPath
		mainFeedCollectionViewController.updateFeedSelection(animations: animations)

		if deselectArticle {
			selectArticle(nil)
		}

		if let ip = indexPath, let node = nodeFor(ip), let sidebarItem = node.representedObject as? SidebarItem {

			self.activityManager.selecting(sidebarItem: sidebarItem)
			self.rootSplitViewController.showColumn(.supplementary)
			setTimelineFeed(sidebarItem, animated: false) {
				AppDefaults.shared.selectedSidebarItem = sidebarItem.sidebarItemID
				completion?()
			}

		} else {

			setTimelineFeed(nil, animated: false) {
				self.activityManager.invalidateSelecting()
				self.rootSplitViewController.showColumn(.primary)
				AppDefaults.shared.selectedSidebarItem = nil
				completion?()
			}

		}
		updateNavigationBarSubtitles(nil)
	}

	func selectPrevFeed() {
		if let indexPath = prevFeedIndexPath {
			selectSidebarItem(indexPath: indexPath, animations: [.navigation, .scroll])
		}
	}

	func selectNextFeed() {
		if let indexPath = nextFeedIndexPath {
			selectSidebarItem(indexPath: indexPath, animations: [.navigation, .scroll])
		}
	}

	func selectAllUnreadFeed(completion: (() -> Void)? = nil) {
		selectListWhenSidebarIsReady(SmartFeedsController.shared.unreadFeed, completion: completion)
	}

	func selectArchiveFeed(completion: (() -> Void)? = nil) {
		selectListWhenSidebarIsReady(SmartFeedsController.shared.archiveFeed, completion: completion)
	}

	func selectAllArticlesFeed(completion: (() -> Void)? = nil) {
		selectListWhenSidebarIsReady(SmartFeedsController.shared.allArticlesFeed, completion: completion)
	}

	func selectStarredFeed(completion: (() -> Void)? = nil) {
		selectListWhenSidebarIsReady(SmartFeedsController.shared.starredFeed, completion: completion)
	}

	func selectArticle(_ article: Article?, animations: Animations = [], articleWindowScrollY: Int? = nil) {
		guard article != currentArticle else {
			return
		}

		currentArticle = article
		activityManager.reading(feed: timelineFeed, article: article)

		if article == nil {
			isArticleViewControllerPending = false
			articleViewController?.article = nil
			rootSplitViewController.showColumn(.supplementary)
			mainTimelineViewController?.updateArticleSelection(animations: animations)
			return
		}

		if !isNavigationDisabled, rootSplitViewController.isCollapsed, !isArticleViewControllerShowing {
			// A push will follow — set to false in ArticleViewController.viewDidAppear.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/5417>
			isArticleViewControllerPending = true
		}

		rootSplitViewController.showColumn(.secondary)
		mainTimelineViewController?.didPushArticleViewController = true

		// Mark article as read before navigating to it, so the read status does not flash unread/read on display
		markArticles(Set([article!]), statusKey: .read, flag: true)

		mainTimelineViewController?.updateArticleSelection(animations: animations)
		articleViewController?.article = article
		if let articleWindowScrollY {
			articleViewController?.restoreScrollPosition = articleWindowScrollY
		}
	}

	func beginSearching() {
		isSearching = true
		preSearchTimelineFeed = timelineFeed
		savedSearchArticles = articles
		savedSearchArticleIDs = Set(articles.map { $0.articleID })
		setTimelineFeed(nil, animated: true)
		selectArticle(nil)
	}

	func endSearching() {
		if let oldTimelineFeed = preSearchTimelineFeed {
			emptyTheTimeline()
			timelineFeed = oldTimelineFeed
			mainTimelineViewController?.reinitializeArticles(resetScroll: true)
			replaceArticles(with: savedSearchArticles!, animated: true)
		} else {
			setTimelineFeed(nil, animated: true)
		}

		lastSearchString = ""
		lastSearchScope = nil
		preSearchTimelineFeed = nil
		savedSearchArticleIDs = nil
		savedSearchArticles = nil
		isSearching = false
		selectArticle(nil)
		mainTimelineViewController?.focus()
	}

	func searchArticles(_ searchString: String, _ searchScope: SearchScope) {

		guard isSearching else {
			return
		}

		if searchString.count < 3 {
			setTimelineFeed(nil, animated: true)
			return
		}

		if searchString != lastSearchString || searchScope != lastSearchScope {

			switch searchScope {
			case .global:
				setTimelineFeed(SmartFeed(delegate: SearchFeedDelegate(searchString: searchString)), animated: true)
			case .timeline:
				setTimelineFeed(SmartFeed(delegate: SearchTimelineFeedDelegate(searchString: searchString, articleIDs: savedSearchArticleIDs!)), animated: true)
			}

			lastSearchString = searchString
			lastSearchScope = searchScope
		}

	}

	func findPrevArticle(_ article: Article) -> Article? {
		guard let index = articles.firstIndex(of: article), index > 0 else {
			return nil
		}
		return articles[index - 1]
	}

	func findNextArticle(_ article: Article) -> Article? {
		guard let index = articles.firstIndex(of: article), index + 1 != articles.count else {
			return nil
		}
		return articles[index + 1]
	}

	func selectPrevArticle() {
		if let article = prevArticle {
			selectArticle(article, animations: [.navigation, .scroll])
		}
	}

	func selectNextArticle() {
		if let article = nextArticle {
			selectArticle(article, animations: [.navigation, .scroll])
		}
	}

	func selectPrevUnread() {

		// This should never happen, but I don't want to risk throwing us
		// into an infinite loop searching for an unread that isn't there.
		if AccountManager.shared.unreadCount < 1 {
			return
		}

		if selectPrevUnreadArticleInTimeline() {
			return
		}

		// Disable navigation only while hopping to the Inbox, so the intermediate
		// timeline isn't pushed. Selecting within the current timeline must be able to
		// push the article view controller.
		isNavigationDisabled = true
		defer {
			isNavigationDisabled = false
		}

		if self.isSearching {
			self.mainTimelineViewController?.hideSearch()
		}

		selectInboxForUnreadWalk {
			self.afterTimelineTransition {
				self.selectPrevUnreadArticleInTimeline()
			}
		}
	}

	func selectNextUnread() {

		// Flush coalesced unread-count updates so folder counts are current.
		CoalescingQueue.standard.performCallsImmediately()

		// This should never happen, but I don't want to risk throwing us
		// into an infinite loop searching for an unread that isn't there.
		if AccountManager.shared.unreadCount < 1 {
			return
		}

		if selectNextUnreadArticleInTimeline() {
			return
		}

		// Disable navigation only while hopping to the Inbox, so the intermediate
		// timeline isn't pushed. Selecting within the current timeline must be able to
		// push the article view controller.
		isNavigationDisabled = true
		defer {
			isNavigationDisabled = false
		}

		if self.isSearching {
			self.mainTimelineViewController?.hideSearch()
		}

		selectInboxForUnreadWalk {
			self.afterTimelineTransition {
				self.selectNextUnreadArticleInTimeline()
			}
		}
	}

	func scrollOrGoToNextUnread() {
		if articleViewController?.canScrollDown() ?? false {
			articleViewController?.scrollPageDown()
		} else {
			selectNextUnread()
		}
	}

	func scrollUp() {
		if articleViewController?.canScrollUp() ?? false {
			articleViewController?.scrollPageUp()
		}
	}

	func markAllAsRead(_ articles: [Article], completion: (() -> Void)? = nil) {
		markArticlesWithUndo(articles, statusKey: .read, flag: true, completion: completion)
	}

	func markAsReadAndShowSidebar(_ articlesToMark: [Article], completion: (() -> Void)? = nil) {
		markAllAsRead(articlesToMark) {
			self.rootSplitViewController.preferredDisplayMode = .twoBesideSecondary
			self.rootSplitViewController.showColumn(.primary, bypassDisplayModeRestriction: true)
			completion?()
		}
	}

	func canMarkAboveAsRead(for article: Article) -> Bool {
		let articlesAboveArray = articles.articlesAbove(article: article)
		return articlesAboveArray.canMarkAllAsRead()
	}

	func markAboveAsRead() {
		guard let currentArticle = currentArticle else {
			return
		}

		markAboveAsRead(currentArticle)
	}

	func markAboveAsRead(_ article: Article) {
		let articlesAboveArray = articles.articlesAbove(article: article)
		markAllAsRead(articlesAboveArray)
	}

	func canMarkBelowAsRead(for article: Article) -> Bool {
		let articleBelowArray = articles.articlesBelow(article: article)
		return articleBelowArray.canMarkAllAsRead()
	}

	func markBelowAsRead() {
		guard let currentArticle = currentArticle else {
			return
		}

		markBelowAsRead(currentArticle)
	}

	func markBelowAsRead(_ article: Article) {
		let articleBelowArray = articles.articlesBelow(article: article)
		markAllAsRead(articleBelowArray)
	}

	func markAsReadForCurrentArticle() {
		if let article = currentArticle {
			markArticlesWithUndo([article], statusKey: .read, flag: true)
		}
	}

	func markAsUnreadForCurrentArticle() {
		if let article = currentArticle {
			markArticlesWithUndo([article], statusKey: .read, flag: false)
		}
	}

	func toggleReadForCurrentArticle() {
		if let article = currentArticle {
			toggleRead(article)
		}
	}

	func showOriginalForCurrentArticle() {
		guard currentArticle != nil else {
			return
		}
		articleViewController?.openInAppBrowser()
	}

	func toggleRead(_ article: Article) {
		guard !article.status.read || article.isAvailableToMarkUnread else {
			return
		}
		markArticlesWithUndo([article], statusKey: .read, flag: !article.status.read)
	}

	func toggleStarredForCurrentArticle() {
		if let article = currentArticle {
			toggleStar(article)
		}
	}

	func toggleStar(_ article: Article) {
		markArticlesWithUndo([article], statusKey: .starred, flag: !article.status.starred)
	}

	func showStatusBar() {
		prefersStatusBarHidden = false
		UIView.animate(withDuration: 0.15) {
			self.rootSplitViewController.setNeedsStatusBarAppearanceUpdate()
		}
	}

	func hideStatusBar() {
		prefersStatusBarHidden = true
		UIView.animate(withDuration: 0.15) {
			self.rootSplitViewController.setNeedsStatusBarAppearanceUpdate()
		}
	}

	func showSettings(scrollToArticlesSection: Bool = false) {
		let settingsNavController = UIStoryboard.settings.instantiateInitialViewController() as! UINavigationController
		let settingsViewController = settingsNavController.topViewController as! SettingsViewController
		settingsViewController.scrollToArticlesSection = scrollToArticlesSection
		settingsNavController.modalPresentationStyle = .formSheet
		settingsViewController.presentingParentController = rootSplitViewController
		rootSplitViewController.present(settingsNavController, animated: true)
	}

	func showCurrentActivity() {
		let hostingController = UIHostingController(rootView: NavigationStack { CurrentActivityView() })
		if let sheet = hostingController.sheetPresentationController {
			sheet.detents = [.medium(), .large()]
			sheet.prefersGrabberVisible = true
		}
		rootSplitViewController.present(hostingController, animated: true)
	}

	func showAddArticle(initialURL: String? = nil) {

		// The sheet appears over the current screen, so the list and article selection stay as they are.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4352>

		var presentedController: UIViewController?
		let addArticleView = AddArticleView(initialURL: initialURL) {
			presentedController?.dismiss(animated: true)
		}
		let hostingController = UIHostingController(rootView: addArticleView)
		hostingController.modalPresentationStyle = .formSheet
		presentedController = hostingController

		// Presenting over an active nav-bar-hosted search bar crashes inside UIKit.
		guard let mainTimelineViewController else {
			rootSplitViewController.present(hostingController, animated: true)
			return
		}
		mainTimelineViewController.hideSearch {
			self.rootSplitViewController.present(hostingController, animated: true)
		}
	}

	func showFullScreenImage(image: UIImage, imageTitle: String?, transition: ImageTransition) {
		let imageVC = UIStoryboard.main.instantiateController(ofType: ImageViewController.self)
		imageVC.image = image
		imageVC.imageTitle = imageTitle
		imageVC.transition = transition
		let navController = UINavigationController(rootViewController: imageVC)
		navController.modalPresentationStyle = .currentContext
		navController.transitioningDelegate = transition
		rootSplitViewController.present(navController, animated: true)
	}

	func showBrowserForArticle(_ article: Article) {
		guard let url = article.preferredURL else {
			return
		}
		UIApplication.shared.open(url, options: [:])
	}

	func showBrowserForCurrentArticle() {
		guard let url = currentArticle?.preferredURL else {
			return
		}
		UIApplication.shared.open(url, options: [:])
	}

	func showInAppBrowser() {
		guard currentArticle != nil else {
			return
		}
		articleViewController?.openInAppBrowser()
	}

	func beganBrowsing(url: URL) {
		activityManager.browsing(url: url)
	}

	func endedBrowsing() {
		activityManager.invalidateBrowsing()
	}

	func navigateToFeeds() {
		if !isRootSplitCollapsed {
			// In three-pane mode, focusing the sidebar deselects the article.
			// In collapsed mode the pop below drives cleanup via navigationController(_:didShow:).
			selectArticle(nil)
		}
		revealColumn(.primary) { [weak self] in
			self?.mainFeedCollectionViewController?.focus()
		}
	}

	func navigateToTimeline() {
		// Only auto-select the first article in three-pane mode, where it populates the
		// detail pane without hiding the timeline.
		let displayMode = rootSplitViewController.displayMode
		let isThreePane = !isRootSplitCollapsed && displayMode != .oneBesideSecondary && displayMode != .secondaryOnly
		if isThreePane && currentArticle == nil && articles.count > 0 {
			selectArticle(articles[0])
		}
		revealColumn(.supplementary) { [weak self] in
			self?.mainTimelineViewController?.focus()
		}
	}

	func navigateToDetail() {
		// If nothing is selected, open the first article so right-arrow reveals the detail even in
		// collapsed and two-pane layouts. selectArticle reveals/pushes the detail column itself.
		if currentArticle == nil {
			guard articles.count > 0 else {
				return
			}
			selectArticle(articles[0])
		}
		revealColumn(.secondary) { [weak self] in
			self?.articleViewController?.focus()
		}
	}

	func selectArticleInCurrentFeed(_ articleID: String, articleWindowScrollY: Int? = nil) {
		if let article = self.articles.first(where: { $0.articleID == articleID }) {
			self.selectArticle(article, articleWindowScrollY: articleWindowScrollY)
		}
	}

	func importTheme(filename: String) {
		do {
			try ArticleThemeImporter.importTheme(controller: rootSplitViewController, url: URL(fileURLWithPath: filename))
		} catch {
			NotificationCenter.default.post(name: .didFailToImportThemeWithError, object: nil, userInfo: ["error": error])
		}

	}

	/// This will dismiss the foremost view controller if the user
	/// has launched from an external action (i.e., a widget tap, or
	/// selecting an article via a notification).
	///
	/// The dismiss is only applicable if the view controller is a
	/// `SFSafariViewController` or `SettingsViewController`,
	/// otherwise, this function does nothing.
	func dismissIfLaunchingFromExternalAction() {
		guard let presentedController = mainFeedCollectionViewController.presentedViewController else {
			return
		}

		if presentedController.isKind(of: SFSafariViewController.self) {
			presentedController.dismiss(animated: true, completion: nil)
		}
		guard let settings = presentedController.children.first as? SettingsViewController else {
			return
		}
		settings.dismiss(animated: true, completion: nil)
	}

}

// MARK: UISplitViewControllerDelegate

extension SceneCoordinator: UISplitViewControllerDelegate {

	func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
		switch proposedTopColumn {
		case .supplementary:
			if currentFeedIndexPath != nil {
				return .supplementary
			} else {
				return .primary
			}
		case .secondary:
			if currentArticle != nil {
				return .secondary
			} else {
				if currentFeedIndexPath != nil {
					return .supplementary
				} else {
					return .primary
				}
			}
		default:
			return .primary
		}
	}

	func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
		AppDefaults.shared.splitViewPreferredDisplayMode = displayMode.rawValue
		mainTimelineViewController?.updateToolbarProgressView(for: displayMode)
	}

	func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
		mainTimelineViewController?.splitViewStateDidChange()
	}

	func splitViewControllerDidExpand(_ svc: UISplitViewController) {
		mainTimelineViewController?.splitViewStateDidChange()
	}

}

// MARK: UINavigationControllerDelegate

extension SceneCoordinator: UINavigationControllerDelegate {

	func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
		guard UIApplication.shared.applicationState != .background else {
			return
		}

		guard rootSplitViewController.isCollapsed else {
			return
		}

		// If we are showing the Feeds and only the feeds start clearing stuff
		if viewController === mainFeedCollectionViewController && !isTimelineViewControllerPending {
			activityManager.invalidateCurrentActivities()
			selectFeed(nil, animations: [.scroll, .select, .navigation])
			return
		}

		// If we are using a phone and navigate away from the detail, clear up the article resources (including activity).
		// Don't clear it if we have pushed an ArticleViewController, but don't yet see it on the navigation stack.
		// This happens when we are going to the next unread and we need to grab another timeline to continue.  The
		// ArticleViewController will be pushed, but we will briefly show the Timeline.  Don't clear things out when that happens.
		// Also skip during state restoration so we don't clear the restored article.
		if viewController === mainTimelineViewController && rootSplitViewController.isCollapsed && !isArticleViewControllerPending && !isRestoringState {
			currentArticle = nil
			mainTimelineViewController?.updateArticleSelection(animations: [.scroll, .select, .navigation])
			activityManager.invalidateReading()

			// Restore any bars hidden by the article controller
			showStatusBar()
			navigationController.setNavigationBarHidden(false, animated: true)
			navigationController.setToolbarHidden(false, animated: true)
			return
		}
	}

}

// MARK: Private

private extension SceneCoordinator {

	// Reveal the destination column, then focus it. Works across collapsed (iPhone),
	// two-pane, and three-pane layouts, so arrow-key navigation isn't limited to the
	// case where all columns are already visible.
	// <https://github.com/Ranchero-Software/NetNewsWire/issues/3138>
	func revealColumn(_ column: UISplitViewController.Column, thenFocus focus: @escaping @MainActor () -> Void) {
		if isRootSplitCollapsed {
			revealColumnInCollapsedMode(column, thenFocus: focus)
		} else {
			rootSplitViewController.showColumn(column, bypassDisplayModeRestriction: true)
			// Defer focus so becomeFirstResponder targets the revealed column, not the outgoing one.
			Task { @MainActor in
				focus()
			}
		}
	}

	func revealColumnInCollapsedMode(_ column: UISplitViewController.Column, thenFocus focus: @escaping @MainActor () -> Void) {
		guard !isNavigationDisabled, let navController = mainFeedCollectionViewController.navigationController else {
			return
		}
		let targetViewController: UIViewController?
		switch column {
		case .primary:
			targetViewController = mainFeedCollectionViewController
		case .supplementary:
			targetViewController = mainTimelineViewController
		case .secondary:
			targetViewController = articleViewController
		default:
			targetViewController = nil
		}
		guard let targetViewController else {
			return
		}

		if navController.topViewController === targetViewController {
			// Already on the destination column — just move focus.
			Task { @MainActor in
				focus()
			}
		} else if navController.viewControllers.contains(targetViewController) {
			// Backward navigation. The pop fires navigationController(_:didShow:), which performs
			// the existing collapsed-mode cleanup. Don't duplicate that here.
			navController.popToViewController(targetViewController, animated: true)
			focusWhenTransitionCompletes(in: navController, thenFocus: focus)
		} else {
			// Forward navigation — push the destination column onto the stack.
			rootSplitViewController.showColumn(column, bypassDisplayModeRestriction: true)
			focusWhenTransitionCompletes(in: navController, thenFocus: focus)
		}
	}

	// Focus once the navigation transition finishes, so becomeFirstResponder lands on the
	// revealed column rather than firing mid-animation. Falls back to the next runloop.
	func focusWhenTransitionCompletes(in navController: UINavigationController, thenFocus focus: @escaping @MainActor () -> Void) {
		if let transitionCoordinator = navController.transitionCoordinator {
			transitionCoordinator.animate(alongsideTransition: nil) { _ in
				focus()
			}
		} else {
			Task { @MainActor in
				focus()
			}
		}
	}

	func markArticlesWithUndo(_ articles: [Article], statusKey: ArticleStatus.Key, flag: Bool, completion: (() -> Void)? = nil) {
		guard let undoManager = undoManager,
			  let markReadCommand = MarkStatusCommand(initialArticles: articles, statusKey: statusKey, flag: flag, undoManager: undoManager, completion: completion) else {
			completion?()
			return
		}
		runCommand(markReadCommand)
	}

	func updateUnreadCount() {
		var count = 0
		for article in articles {
			if !article.status.read {
				count += 1
			}
		}
		timelineUnreadCount = count
	}

	func rebuildArticleDictionaries() {
		var idDictionary = [String: Article]()

		for article in articles {
			idDictionary[article.articleID] = article
		}

		_idToArticleDictionary = idDictionary
		articleDictionaryNeedsUpdate = false
	}

	/// Selects a list once a sidebar snapshot has been applied, so the list has an index path
	/// even when this runs at launch (a widget, quick action or keyboard shortcut).
	func selectListWhenSidebarIsReady(_ sidebarItem: SidebarItem, animations: Animations = [.navigation, .scroll], completion: (() -> Void)? = nil) {
		rebuildBackingStores {
			self.selectFeed(sidebarItem, animations: animations, completion: completion)
		}
	}

	/// Every unread article is in the Inbox, so an unread walk that runs out of
	/// unread articles in the current list continues there.
	func selectInboxForUnreadWalk(completion: @escaping () -> Void) {
		guard let indexPath = indexPathFor(SmartFeedsController.shared.unreadFeed) else {
			completion()
			return
		}
		selectSidebarItem(indexPath: indexPath, animations: [.scroll, .navigation], deselectArticle: false) {
			self.currentArticle = nil
			completion()
		}
	}

	/// The supplementary push from selectSidebarItem may still be animating when
	/// its completion fires — the async data fetch can outrun the push animation
	/// in compact mode. Wait for the in-flight transition before pushing the
	/// article view controller, or UIKit aborts with NSInternalInconsistencyException
	/// from -[UINavigationController pushViewController:transition:forceImmediate:].
	func afterTimelineTransition(_ block: @escaping @MainActor () -> Void) {
		if let coordinator = mainTimelineViewController?.navigationController?.transitionCoordinator {
			coordinator.animate(alongsideTransition: nil) { _ in
				block()
			}
		} else {
			block()
		}
	}

	static var rebuildCount = 0

	func rebuildBackingStores(initialLoad: Bool = false, completion: (() -> Void)? = nil) {
#if DEBUG
		if initialLoad {
			Self.logger.debug("SceneCoordinator: rebuildBackingStores: #\(Self.rebuildCount) initialLoad == true")
		} else {
			Self.logger.debug("SceneCoordinator: rebuildBackingStores: #\(Self.rebuildCount)")
		}
		Self.rebuildCount += 1
#endif

		treeController.rebuild()

		let snapshot = createSidebarSnapshot()
		mainFeedCollectionViewController.applySnapshot(snapshot, animatingDifferences: !initialLoad) { [weak self] in
			guard let self else {
				return
			}
			// The data source reflects the new snapshot only after the apply
			// completes — recomputing earlier would read the old layout.
			if self.currentFeedIndexPath != nil {
				self.currentFeedIndexPath = self.indexPathFor(self.timelineFeed as AnyObject)
			}
			completion?()
		}
	}

	/// One section holding the lists. The tree's only top-level node is the lists group.
	private func createSidebarSnapshot() -> NSDiffableDataSourceSnapshot<String, SidebarItemNode> {
		var snapshot = NSDiffableDataSourceSnapshot<String, SidebarItemNode>()
		let sectionID = ""
		snapshot.appendSections([sectionID])
		for groupNode in treeController.rootNode.childNodes {
			snapshot.appendItems(groupNode.childNodes.map { SidebarItemNode($0) }, toSection: sectionID)
		}
		return snapshot
	}

	func indexPathFor(_ object: AnyObject) -> IndexPath? {
		guard let node = treeController.rootNode.descendantNodeRepresentingObject(object) else {
			return nil
		}
		return indexPathFor(node)
	}

	func setTimelineFeed(_ sidebarItem: SidebarItem?, animated: Bool, completion: (() -> Void)? = nil) {
		timelineFeed = sidebarItem

		fetchAndReplaceArticlesAsync(animated: animated) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: true)
			completion?()
		}
	}

	// MARK: Select Prev Unread

	@discardableResult
	func selectPrevUnreadArticleInTimeline() -> Bool {
		let startingRow: Int = {
			if let articleRow = currentArticleRow {
				return articleRow
			} else {
				return articles.count - 1
			}
		}()

		return selectPrevArticleInTimeline(startingRow: startingRow)
	}

	func selectPrevArticleInTimeline(startingRow: Int) -> Bool {

		guard startingRow >= 0 else {
			return false
		}

		for i in (0...startingRow).reversed() {
			let article = articles[i]
			if !article.status.read {
				selectArticle(article)
				return true
			}
		}

		return false

	}

	// MARK: Select Next Unread

	@discardableResult
	func selectFirstUnreadArticleInTimeline() -> Bool {
		return selectNextArticleInTimeline(startingRow: 0, animated: true)
	}

	@discardableResult
	func selectNextUnreadArticleInTimeline() -> Bool {
		let startingRow: Int = {
			if let articleRow = currentArticleRow {
				return articleRow + 1
			} else {
				return 0
			}
		}()

		return selectNextArticleInTimeline(startingRow: startingRow, animated: false)
	}

	func selectNextArticleInTimeline(startingRow: Int, animated: Bool) -> Bool {

		guard startingRow < articles.count else {
			return false
		}

		for i in startingRow..<articles.count {
			let article = articles[i]
			if !article.status.read {
				selectArticle(article, animations: [.scroll, .navigation])
				return true
			}
		}

		return false

	}

	// MARK: Fetching Articles

	func emptyTheTimeline() {
		if !articles.isEmpty {
			replaceArticles(with: Set<Article>(), animated: false)
		}
	}

	func sortParametersDidChange() {
		replaceArticles(with: Set(articles), animated: true)
	}

	func replaceArticles(with unsortedArticles: Set<Article>, animated: Bool) {
		let sortedArticles = Array(unsortedArticles).sortedByDate(sortDirection, groupByFeed: groupByFeed)
		replaceArticles(with: sortedArticles, animated: animated)
	}

	func replaceArticles(with sortedArticles: ArticleArray, animated: Bool) {
		if articles != sortedArticles {
			articles = sortedArticles

			// Update currentArticle to the new instance if it's still in the timeline.
			// If the article is no longer in the timeline, keep showing it anyway -
			// don't blank the user's screen just because the article filtered out.
			// Skip during state restoration so the restored article stays open.
			if !isRestoringState, let currentArticle {
				if let newArticle = sortedArticles.first(where: { $0.articleID == currentArticle.articleID && $0.accountID == currentArticle.accountID }) {
					self.currentArticle = newArticle
				}
			}

			IconImageCache.shared.prefetchImagesForArticles(articles)
			updateUnreadCount()
			mainTimelineViewController?.reloadArticles(animated: animated)
		}
	}

	func queueFetchAndMergeArticles() {
		fetchAndMergeArticlesQueue.add(self, #selector(fetchAndMergeArticlesAsync))
	}

	@objc func fetchAndMergeArticlesAsync() {
		fetchAndMergeArticlesAsync(animated: true) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
			self.mainTimelineViewController?.restoreSelectionIfNecessary(adjustScroll: false)
		}
	}

	func fetchAndMergeArticlesAsync(animated: Bool = true, completion: (() -> Void)? = nil) {

		guard let timelineFeed = timelineFeed else {
			return
		}

		fetchUnsortedArticlesAsync(for: [timelineFeed]) { [weak self] (unsortedArticles) in
			// Merge articles by articleID. For any unique articleID in current articles, add to unsortedArticles.
			guard let strongSelf = self else {
				return
			}
			let unsortedArticleIDs = unsortedArticles.articleIDs()
			var updatedArticles = unsortedArticles
			for article in strongSelf.articles {
				if !unsortedArticleIDs.contains(article.articleID) {
					updatedArticles.insert(article)
				}
				if article.account?.existingFeed(withFeedID: article.feedID) == nil {
					updatedArticles.remove(article)
				}
			}

			strongSelf.replaceArticles(with: updatedArticles, animated: animated)
			completion?()
		}

	}

	func cancelPendingAsyncFetches() {
		fetchSerialNumber += 1
		fetchRequestQueue.cancelAllRequests()
	}

	func fetchAndReplaceArticlesAsync(animated: Bool, emptyFirst: Bool = true, completion: @escaping () -> Void) {
		// To be called when we need to do an entire fetch, but an async delay is okay.
		// Example: we have the Today feed selected, and the calendar day just changed.
		cancelPendingAsyncFetches()
		if emptyFirst {
			emptyTheTimeline()
		}
		guard let timelineFeed = timelineFeed else {
			completion()
			return
		}

		var fetchers = [ArticleFetcher]()
		fetchers.append(timelineFeed)
		if exceptionArticleFetcher != nil {
			fetchers.append(exceptionArticleFetcher!)
			exceptionArticleFetcher = nil
		}

		fetchUnsortedArticlesAsync(for: fetchers) { [weak self] (articles) in
			self?.replaceArticles(with: articles, animated: animated)
			completion()
		}

	}

	func fetchUnsortedArticlesAsync(for representedObjects: [Any], completion: @escaping ArticleSetBlock) {
		// The callback will *not* be called if the fetch is no longer relevant — that is,
		// if it’s been superseded by a newer fetch, or the timeline was emptied, etc., it won’t get called.
		precondition(Thread.isMainThread)
		cancelPendingAsyncFetches()

		let fetchers = representedObjects.compactMap { $0 as? ArticleFetcher }
		let fetchOperation = FetchRequestOperation(id: fetchSerialNumber, hidingReadArticlesState: hidingReadArticlesState, fetchers: fetchers) { [weak self] (articles, operation) in
			precondition(Thread.isMainThread)
			guard !operation.isCanceled, let strongSelf = self, operation.id == strongSelf.fetchSerialNumber else {
				return
			}
			completion(articles)
		}

		fetchRequestQueue.add(fetchOperation)
	}

	// MARK: NSUserActivity

	func handleSelectFeed(_ userInfo: [AnyHashable: Any]?) {
		Self.logger.debug("SceneCoordinator: handleSelectFeed")

		// Only the lists are in the sidebar. A feed or folder from an older activity has nowhere to go.
		guard let userInfo,
			  let sidebarItemIDUserInfo = userInfo[UserInfoKey.sidebarItemID] as? [String: String],
			  let sidebarItemID = SidebarItemIdentifier(userInfo: sidebarItemIDUserInfo),
			  let smartFeed = SmartFeedsController.shared.find(by: sidebarItemID) else {
			return
		}

		rebuildBackingStores(initialLoad: true) {
			if let indexPath = self.indexPathFor(smartFeed) {
				self.selectSidebarItem(indexPath: indexPath) {
					self.mainFeedCollectionViewController.focus()
				}
			}
		}
	}

	func handleReadArticle(_ userInfo: [AnyHashable: Any]?) {
		guard let userInfo else {
			return
		}

		// A deep link supersedes any in-flight state restoration.
		isRestoringState = false

		guard let articlePathUserInfo = userInfo[UserInfoKey.articlePath] as? [AnyHashable: Any],
			  let accountID = articlePathUserInfo[ArticlePathKey.accountID] as? String,
			  let articleID = articlePathUserInfo[ArticlePathKey.articleID] as? String,
			  let account = AccountManager.shared.existingAccount(accountID: accountID) else {
			return
		}

		exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: articleID)

		if restoreFeedSelection(userInfo, articleID: articleID) {
			return
		}

		// Every saved article is in All.
		selectAllArticlesFeed {
			self.selectArticleInCurrentFeed(articleID)
		}
	}

	func restoreFeedSelection(_ userInfo: [AnyHashable: Any], articleID: String) -> Bool {
		guard let sidebarItemIDUserInfo = (userInfo[UserInfoKey.sidebarItemID] ?? userInfo[UserInfoKey.feedIdentifier]) as? [String: String],
			  let sidebarItemID = SidebarItemIdentifier(userInfo: sidebarItemIDUserInfo) else {
			return false
		}

		// A handoff or deep link opens the article at the top — the persisted scroll
		// position belongs to launch state restoration, not to this article.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5243>
		return selectSidebarItemAndArticle(sidebarItemID: sidebarItemID, articleID: articleID)
	}

	func selectSidebarItemAndArticle(sidebarItemID: SidebarItemIdentifier, articleID: String) -> Bool {
		guard let sidebarItemNode = nodeFor(sidebarItemID: sidebarItemID), let sidebarItemIndexPath = indexPathFor(sidebarItemNode) else {
			return false
		}

		selectSidebarItem(indexPath: sidebarItemIndexPath) {
			self.selectArticleInCurrentFeed(articleID)
		}

		return true
	}
}
