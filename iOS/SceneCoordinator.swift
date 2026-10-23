//
//  NavigationModelController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/21/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import os
import Account
import Articles
import RSCore
import SwiftUI
import Images

enum ShowFeedName {
	case none
	case byline
	case feed
}

/// Runs the window: a two-column split view with the list (the Queue, with the Archive pushed
/// over it) and the article. On iPhone it collapses to one navigation stack: Queue, Archive, article.
@MainActor final class SceneCoordinator: NSObject, UndoableCommandRunner {
	var undoableCommands = [UndoableCommand]()
	var undoManager: UndoManager? {
		return rootSplitViewController.undoManager
	}

	lazy var webViewProvider = WebViewProvider(coordinator: self)

	private var activityManager = ActivityManager()

	private var rootSplitViewController: RootSplitViewController!

	/// The Queue, the list column's root. It's on screen at every launch.
	private let queueViewController: MainTimelineViewController?
	/// The Archive, while it's pushed over the Queue.
	private var archiveViewController: MainTimelineViewController?
	/// The list on screen: `timelineFeed` and `articles` belong to it.
	private var mainTimelineViewController: MainTimelineViewController? {
		archiveViewController ?? queueViewController
	}
	private let articleViewController: ArticleViewController?

	/// The navigation controller of the list column. When collapsed, the article is pushed onto it too.
	private var listNavigationController: UINavigationController? {
		queueViewController?.navigationController
	}

	/// The Queue's rows while the Archive is open, shown again as soon as it closes.
	private var queueArticlesUnderArchive: ArticleArray?

	private let fetchAndMergeArticlesQueue = CoalescingQueue(name: "Fetch and Merge Articles", interval: 0.5)
	private let saveColumnWidthsQueue = CoalescingQueue(name: "Save Column Widths", interval: 0.5)
	private var fetchSerialNumber = 0
	private let fetchRequestQueue = FetchRequestQueue()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "SceneCoordinator")

	private var isRestoringState = false

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

	var stateRestorationActivity: NSUserActivity {
		activityManager.stateRestorationActivity
	}

	var isRootSplitCollapsed: Bool {
		return rootSplitViewController.isCollapsed
	}

	// In collapsed mode, the article view is in the window only while it’s on top of the navigation stack.
	var isArticleViewControllerShowing: Bool {
		articleViewController?.viewIfLoaded?.window != nil
	}

	private var exceptionArticleFetcher: ArticleFetcher?
	private(set) var timelineFeed: SidebarItem? {
		didSet {
			updateNavigationBarSubtitles(nil)
		}
	}

	var timelineMiddleIndexPath: IndexPath?

	// Every list mixes articles from many sites, so each row shows its site and icon.
	let showFeedNames = ShowFeedName.feed
	let showIcons = true

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

	var timelineUnreadCount: Int = 0 {
		didSet {
			updateNavigationBarSubtitles(nil)
		}
	}

	private var queue: PseudoFeed {
		SmartFeedsController.shared.unreadFeed
	}

	private var archive: PseudoFeed {
		SmartFeedsController.shared.archiveFeed
	}

	/// "12 in Queue" while the Queue is showing and has articles. Archive shows no count.
	private var queueCountSubtitle: String? {
		guard timelineFeed as AnyObject? === queue, timelineUnreadCount > 0 else {
			return nil
		}
		let format = NSLocalizedString("%d in Queue", comment: "Timeline subtitle: the number of articles in the Queue")
		return String.localizedStringWithFormat(format, timelineUnreadCount)
	}

	private static let minimumListWidth: CGFloat = 280
	private static let maximumListWidth: CGFloat = 440

	private static func clampListWidth(_ width: CGFloat) -> CGFloat {
		if width < minimumListWidth {
			return minimumListWidth
		}
		if width > maximumListWidth {
			return maximumListWidth
		}
		return width
	}

	init(rootSplitViewController: RootSplitViewController) {
		self.rootSplitViewController = rootSplitViewController
		rootSplitViewController.minimumPrimaryColumnWidth = Self.minimumListWidth
		rootSplitViewController.maximumPrimaryColumnWidth = Self.maximumListWidth
		let savedListWidth = AppDefaults.shared.timelineWidth.map { CGFloat($0) } ?? 320
		rootSplitViewController.preferredPrimaryColumnWidth = Self.clampListWidth(savedListWidth)
		rootSplitViewController.preferredSplitBehavior = .tile

		self.queueViewController = rootSplitViewController.viewController(for: .primary) as? MainTimelineViewController
		self.articleViewController = rootSplitViewController.viewController(for: .secondary) as? ArticleViewController

		super.init()

		queueViewController?.coordinator = self
		queueViewController?.list = SmartFeedsController.shared.unreadFeed
		articleViewController?.coordinator = self

		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(containerChildrenDidChange(_:)), name: .ChildrenDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountStateDidChange(_:)), name: .AccountStateDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDeleteArticles(_:)), name: .AccountDidDeleteArticles, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(updateNavigationBarSubtitles(_:)), name: .progressInfoDidChange, object: CombinedRefreshProgress.shared)

		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			Task { @MainActor in
				self?.userDefaultsDidChange()
			}
		}
	}

	/// Every launch opens on the Queue. The article that was open comes back, at its scroll
	/// position, if it's still in the Queue.
	func restoreWindowState(restoreSelection: Bool) {
		Self.logger.debug("SceneCoordinator: restoreWindowState")

		let stateInfo = StateRestorationInfo()
		isRestoringState = restoreSelection

		activityManager.selecting(sidebarItem: queue)
		setTimelineFeed(queue, animated: false) {
			guard restoreSelection else {
				return
			}
			self.restoreSelectedArticle(stateInfo)
		}
	}

	private func restoreSelectedArticle(_ stateInfo: StateRestorationInfo) {
		defer {
			isRestoringState = false
		}

		guard let articleSpecifier = stateInfo.selectedArticle,
			  let article = articles.article(matching: articleSpecifier) else {
			return
		}

		// Disable animation since this function runs only during state restoration on launch.
		UIView.performWithoutAnimation {
			selectArticle(article, articleWindowScrollY: stateInfo.articleWindowScrollY)
		}
	}

	func handle(_ activity: NSUserActivity) {
		guard let activityType = ActivityType(rawValue: activity.activityType) else {
			return
		}

		switch activityType {
		case .addFeedIntent:
			// Add Article just presents a sheet, so the list and article stay as they are.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/4352>
			showAddArticle()
		case .selectFeed:
			handleSelectFeed(activity.userInfo)
		case .readArticle:
			handleReadArticle(activity.userInfo)
		case .restoration:
			break
		}
	}

	func resetFocus() {
		mainTimelineViewController?.focus()
	}

	// MARK: Notifications

	@objc func statusesDidChange(_ note: Notification) {
		updateUnreadCount()
		if let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String> {
			keepOnlyListMembers(changed: articleIDs)
		}
	}

	/// Queue shows only articles not yet archived and Archive only archived ones. An article
	/// whose status changed leaves the list it no longer belongs in (an open article stays open,
	/// unless it was archived here, which closes it first);
	/// one that now belongs (undo, or a change from another device) is fetched in.
	private func keepOnlyListMembers(changed articleIDs: Set<String>) {
		let smartFeeds = SmartFeedsController.shared
		guard let list = timelineFeed as AnyObject?, list === smartFeeds.unreadFeed || list === smartFeeds.archiveFeed else {
			return
		}
		let remaining = articles.filter { !articleIDs.contains($0.articleID) || smartFeeds.list(for: $0) === list }
		if remaining.count != articles.count {
			replaceArticles(with: remaining, animated: true)
		}
		if articleIDs.contains(where: { articleID in !articles.contains { $0.articleID == articleID } }) {
			queueFetchAndMergeArticles()
		}
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
		// Don’t interfere with any fetch requests that we may have initiated before the app was returned to the foreground.
		// For example if you select Queue from the Home Screen Quick actions, you can start a request before we are
		// in the foreground.
		if !fetchRequestQueue.isAnyCurrentRequest {
			queueFetchAndMergeArticles()
		}
		AccountManager.shared.repairStatusesIfNeeded()
	}

	/// Updates the list's navigation bar subtitle in response to list changes, Queue count changes,
	/// `progressInfoDidChange` notifications, and a timed refresh every 60s.
	///
	/// While the Queue has articles, its count ("12 in Queue") is the subtitle. Otherwise (an empty
	/// Queue, or the Archive) it's the sync status: "Syncing…", then "Synced <#relative_time#>".
	///
	/// - Parameter note: Optional `Notification`
	@objc func updateNavigationBarSubtitles(_ note: Notification?) {
		mainTimelineViewController?.updateNavigationBarSubtitle(queueCountSubtitle ?? syncStatusSubtitle)
		scheduleNavigationBarSubtitleUpdate()
	}

	private var syncStatusSubtitle: String {
		guard CombinedRefreshProgress.shared.progressInfo.isComplete else {
			return NSLocalizedString("Syncing…", comment: "Syncing…")
		}
		// "Synced Just Now" until a minute has passed since the sync.
		guard let lastRefreshDate = AccountManager.shared.lastRefreshCompletedDate, Date.now > lastRefreshDate.addingTimeInterval(60) else {
			return NSLocalizedString("Synced Just Now", comment: "Synced Just Now")
		}
		let relativeDateTimeFormatter = RelativeDateTimeFormatter()
		relativeDateTimeFormatter.dateTimeStyle = .named
		let refreshed = relativeDateTimeFormatter.localizedString(for: lastRefreshDate, relativeTo: Date())
		let localizedRefreshText = NSLocalizedString("Synced %@", comment: "Synced")
		return NSString.localizedStringWithFormat(localizedRefreshText as NSString, refreshed) as String
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

	/// A list left the navigation stack. When it's the open Archive, the user closed it with the
	/// back button or a swipe (the coordinator's own pops forget the Archive first), and the Queue
	/// is the list again.
	func timelineViewControllerDidClose(_ timelineViewController: MainTimelineViewController) {
		guard timelineViewController === archiveViewController else {
			return
		}
		archiveViewController = nil
		deselectArticle(animations: [])
		showList(queue)
	}

	func timelineDidLayout() {
		saveColumnWidthsQueue.add(self, #selector(saveListWidth))
	}

	@objc private func saveListWidth() {
		guard !rootSplitViewController.isCollapsed, rootSplitViewController.displayMode != .secondaryOnly else {
			return
		}
		let width = mainTimelineViewController?.view.bounds.width ?? 0
		guard width > 0 else {
			return
		}
		AppDefaults.shared.timelineWidth = Int(Self.clampListWidth(width))
	}

	func suspend() {
		fetchAndMergeArticlesQueue.performCallsImmediately()
		fetchRequestQueue.cancelAllRequests()
	}

	private func isCurrentArticle(_ article: Article) -> Bool {
		guard let currentArticle else {
			return false
		}
		return article.articleID == currentArticle.articleID && article.accountID == currentArticle.accountID
	}

	func articleFor(_ articleID: String) -> Article? {
		// Check if it’s the currently displayed article
		if let currentArticle, currentArticle.articleID == articleID {
			return currentArticle
		}
		return idToArticleDictionary[articleID]
	}

	/// Shows the Queue, closing the Archive if it's open.
	func selectQueue(completion: (() -> Void)? = nil) {
		selectList(queue, completion: completion)
	}

	/// Shows the Archive, pushed over the Queue.
	func selectArchive(completion: (() -> Void)? = nil) {
		selectList(archive, completion: completion)
	}

	func selectArticle(_ article: Article?, animations: Animations = [], articleWindowScrollY: Int? = nil) {
		guard article != currentArticle else {
			return
		}

		guard let article else {
			deselectArticle(animations: animations)
			showCurrentList()
			return
		}

		currentArticle = article
		activityManager.reading(feed: timelineFeed, article: article)

		// While the Archive is being pushed or popped, the outgoing article can still be in the window,
		// but the push comes after the transition.
		let isListTransitionInProgress = listNavigationController?.transitionCoordinator != nil
		if rootSplitViewController.isCollapsed, isListTransitionInProgress || !isArticleViewControllerShowing {
			// A push will follow — set to false in ArticleViewController.viewDidAppear.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/5417>
			isArticleViewControllerPending = true
		}

		showArticleColumn()
		mainTimelineViewController?.didPushArticleViewController = true

		mainTimelineViewController?.updateArticleSelection(animations: animations)
		articleViewController?.article = article
		if let articleWindowScrollY {
			articleViewController?.restoreScrollPosition = articleWindowScrollY
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
		if let currentArticle, let article = findPrevArticle(currentArticle) {
			selectArticle(article, animations: [.navigation, .scroll])
		}
	}

	func selectNextArticle() {
		if let currentArticle, let article = findNextArticle(currentArticle) {
			selectArticle(article, animations: [.navigation, .scroll])
		}
	}

	/// Space bar: page the article down.
	func scrollDown() {
		if articleViewController?.canScrollDown() ?? false {
			articleViewController?.scrollPageDown()
		}
	}

	func scrollUp() {
		if articleViewController?.canScrollUp() ?? false {
			articleViewController?.scrollPageUp()
		}
	}

	func toggleReadForCurrentArticle() {
		if let article = currentArticle {
			toggleRead(article)
		}
	}

	/// Archiving the open article, or moving it back to the Queue, closes it first, as in Mail:
	/// on iPhone the article pops off and its row then leaves the list in view.
	func toggleRead(_ article: Article) {
		guard !article.status.read || article.isAvailableToMarkUnread else {
			return
		}
		let flag = !article.status.read
		guard isCurrentArticle(article) else {
			markArticlesWithUndo([article], statusKey: .read, flag: flag)
			return
		}
		closeArticle { [weak self] in
			self?.markArticlesWithUndo([article], statusKey: .read, flag: flag)
		}
	}

	func showSettings() {
		let settingsNavController = UIStoryboard.settings.instantiateInitialViewController() as! UINavigationController
		let settingsViewController = settingsNavController.topViewController as! SettingsViewController
		settingsNavController.modalPresentationStyle = .formSheet
		settingsViewController.presentingParentController = rootSplitViewController
		rootSplitViewController.present(settingsNavController, animated: true)
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
		rootSplitViewController.present(hostingController, animated: true)
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

	/// Left arrow in the article: back to the list.
	func navigateToTimeline() {
		// With the list beside the article, an empty article pane gets the first article.
		let isListBesideArticle = !isRootSplitCollapsed && rootSplitViewController.displayMode == .oneBesideSecondary
		if isListBesideArticle && currentArticle == nil && articles.count > 0 {
			selectArticle(articles[0])
		}
		revealColumn(.primary) { [weak self] in
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

	/// This will dismiss the foremost view controller if the user
	/// has launched from an external action (i.e., a widget tap, or
	/// selecting an article via a notification).
	///
	/// The dismiss is only applicable if the view controller is
	/// `SettingsViewController`, otherwise, this function does nothing.
	func dismissIfLaunchingFromExternalAction() {
		guard let presentedController = rootSplitViewController.presentedViewController else {
			return
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
		if proposedTopColumn == .secondary && currentArticle != nil {
			return .secondary
		}
		return .primary
	}

	func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
		queueViewController?.splitViewStateDidChange()
		archiveViewController?.splitViewStateDidChange()
	}

	func splitViewControllerDidExpand(_ svc: UISplitViewController) {
		queueViewController?.splitViewStateDidChange()
		archiveViewController?.splitViewStateDidChange()
	}

}

// MARK: Private

private extension SceneCoordinator {

	// MARK: Lists

	/// Shows the Queue or the Archive. Changing lists closes the open article.
	/// - Parameters:
	///   - revealList: When the list is already showing, pop back to it (on iPhone) or show its column.
	///   - completion: Runs once the list's articles are loaded, so it can select one of them.
	func selectList(_ list: PseudoFeed, revealList: Bool = true, completion: (() -> Void)? = nil) {
		Self.logger.debug("SceneCoordinator: selectList")

		// Choosing a list supersedes any in-flight launch restoration.
		isRestoringState = false

		guard list !== timelineFeed as AnyObject? else {
			if revealList {
				showCurrentList()
			}
			guard let completion else {
				return
			}
			// The list may still be loading (at launch), or lack an article a deep link is about to open.
			fetchAndReplaceArticlesAsync(animated: true, emptyFirst: false) {
				self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
				completion()
			}
			return
		}

		deselectArticle(animations: [])

		if list === archive {
			pushArchiveViewController()
		} else {
			popToQueueViewController()
		}
		showList(list, completion: completion)
	}

	func pushArchiveViewController() {
		guard let queueViewController, let navigationController = listNavigationController else {
			return
		}
		let archiveViewController = UIStoryboard.main.instantiateController(ofType: MainTimelineViewController.self)
		archiveViewController.coordinator = self
		archiveViewController.list = archive
		self.archiveViewController = archiveViewController

		// Any article open on iPhone closes as the Archive takes its place.
		navigationController.setViewControllers([queueViewController, archiveViewController], animated: true)
		showListColumnIfExpanded()
	}

	func popToQueueViewController() {
		archiveViewController = nil
		guard let queueViewController, let navigationController = listNavigationController else {
			return
		}
		navigationController.popToViewController(queueViewController, animated: true)
		showListColumnIfExpanded()
	}

	func showListColumnIfExpanded() {
		if !rootSplitViewController.isCollapsed {
			rootSplitViewController.showColumn(.primary)
		}
	}

	/// Makes `list` the current list and loads its articles. The Queue's rows come back at once
	/// when the Archive closes, then they're refreshed.
	func showList(_ list: PseudoFeed, completion: (() -> Void)? = nil) {
		activityManager.selecting(sidebarItem: list)

		guard list !== archive else {
			if timelineFeed as AnyObject? === queue {
				queueArticlesUnderArchive = articles
			}
			setTimelineFeed(list, animated: false, completion: completion)
			return
		}

		timelineFeed = list
		if let queueArticlesUnderArchive {
			replaceArticles(with: queueArticlesUnderArchive, animated: false)
		}
		queueArticlesUnderArchive = nil
		fetchAndReplaceArticlesAsync(animated: true, emptyFirst: false) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: false)
			completion?()
		}
	}

	/// Clears the article selection without navigating.
	func deselectArticle(animations: Animations) {
		guard currentArticle != nil else {
			return
		}
		currentArticle = nil
		activityManager.reading(feed: timelineFeed, article: nil)
		isArticleViewControllerPending = false
		articleViewController?.article = nil
		mainTimelineViewController?.updateArticleSelection(animations: animations)
	}

	/// Brings the current list into view: on iPhone, pops the article off it.
	func showCurrentList() {
		guard rootSplitViewController.isCollapsed else {
			rootSplitViewController.showColumn(.primary)
			return
		}
		guard let mainTimelineViewController, let navigationController = listNavigationController,
			  navigationController.topViewController !== mainTimelineViewController,
			  navigationController.viewControllers.contains(mainTimelineViewController) else {
			return
		}
		navigationController.popToViewController(mainTimelineViewController, animated: true)
	}

	/// Closes the open article and brings the list into view, then runs `completion`. On iPhone
	/// the article stays drawn while it pops, and `completion` waits for the list to show.
	func closeArticle(completion: @escaping () -> Void) {
		guard rootSplitViewController.isCollapsed else {
			selectArticle(nil)
			completion()
			return
		}
		showCurrentList()
		let finish = { [weak self] in
			self?.deselectArticle(animations: [])
			completion()
		}
		guard let transitionCoordinator = listNavigationController?.transitionCoordinator else {
			finish()
			return
		}
		let isScheduled = transitionCoordinator.animate(alongsideTransition: nil) { _ in
			finish()
		}
		if !isScheduled {
			finish()
		}
	}

	/// Shows the article column; on iPhone, pushes the article. A list push or pop that's still
	/// animating finishes first.
	func showArticleColumn() {
		let showColumn = { [weak self] in
			self?.rootSplitViewController.showColumn(.secondary)
		}
		guard let transitionCoordinator = listNavigationController?.transitionCoordinator else {
			showColumn()
			return
		}
		let isScheduled = transitionCoordinator.animate(alongsideTransition: nil) { _ in
			showColumn()
		}
		if !isScheduled {
			showColumn()
		}
	}

	// Reveal the destination column, then focus it. Works across collapsed (iPhone)
	// and two-column layouts, so arrow-key navigation isn’t limited to the
	// case where both columns are already visible.
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
		guard let navController = listNavigationController else {
			return
		}
		let targetViewController: UIViewController?
		switch column {
		case .primary:
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
			// Backward navigation. The list's viewDidAppear clears the article selection
			// (MainTimelineViewController.deselectIfNecessary). Don’t duplicate that here.
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
		if count != timelineUnreadCount {
			timelineUnreadCount = count
		}
	}

	func rebuildArticleDictionaries() {
		var idDictionary = [String: Article]()

		for article in articles {
			idDictionary[article.articleID] = article
		}

		_idToArticleDictionary = idDictionary
		articleDictionaryNeedsUpdate = false
	}

	func setTimelineFeed(_ sidebarItem: SidebarItem?, animated: Bool, completion: (() -> Void)? = nil) {
		timelineFeed = sidebarItem

		fetchAndReplaceArticlesAsync(animated: animated) {
			self.mainTimelineViewController?.reinitializeArticles(resetScroll: true)
			completion?()
		}
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
		let sortedArticles = Array(unsortedArticles).sortedByDate(sortDirection)
		replaceArticles(with: sortedArticles, animated: animated)
	}

	// Always tells the timeline, even when the articles look unchanged — a matching model
	// doesn’t mean the displayed rows match.
	func replaceArticles(with sortedArticles: ArticleArray, animated: Bool) {
		articles = sortedArticles

		// Update currentArticle to the new instance if it’s still in the timeline.
		// If the article is no longer in the timeline, keep showing it anyway -
		// don’t blank the user’s screen just because the article filtered out.
		// Skip during state restoration so the restored article stays open.
		if !isRestoringState, let newArticle = sortedArticles.first(where: isCurrentArticle), newArticle !== currentArticle {
			currentArticle = newArticle
		}

		IconImageCache.shared.prefetchImagesForArticles(articles)
		updateUnreadCount()
		mainTimelineViewController?.reloadArticles(animated: animated)
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

	/// Fetches the whole list again. With `emptyFirst`, the rows are cleared first; without it, they stay
	/// until the new ones arrive. An article a deep link is about to open (`exceptionArticleFetcher`) is
	/// fetched too, even when it isn't in the list. The open article isn't kept when it has left the list:
	/// every caller is about to close it or open another one, and keeping it would put an article that was
	/// just archived back in the Queue.
	func fetchAndReplaceArticlesAsync(animated: Bool, emptyFirst: Bool = true, completion: @escaping () -> Void) {
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
		if let exceptionArticleFetcher {
			fetchers.append(exceptionArticleFetcher)
			self.exceptionArticleFetcher = nil
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
		let fetchOperation = FetchRequestOperation(id: fetchSerialNumber, fetchers: fetchers) { [weak self] (articles, operation) in
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

		// Only the Queue and the Archive can be shown. A feed or folder from an older activity has nowhere to go.
		guard let userInfo,
			  let sidebarItemIDUserInfo = userInfo[UserInfoKey.sidebarItemID] as? [String: String],
			  let sidebarItemID = SidebarItemIdentifier(userInfo: sidebarItemIDUserInfo),
			  let list = SmartFeedsController.shared.find(by: sidebarItemID) else {
			return
		}

		selectList(list) {
			self.mainTimelineViewController?.focus()
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

		// Open the list the article is in.
		Task { @MainActor in
			let article = await account.fetchArticlesAsync(.articleIDs([articleID])).first
			let list = article.map { SmartFeedsController.shared.list(for: $0) } ?? self.queue
			self.selectList(list, revealList: false) {
				self.selectArticleInCurrentFeed(articleID)
			}
		}
	}

	func restoreFeedSelection(_ userInfo: [AnyHashable: Any], articleID: String) -> Bool {
		// A handoff or deep link opens the article at the top — the persisted scroll
		// position belongs to launch state restoration, not to this article.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5243>
		guard let sidebarItemIDUserInfo = (userInfo[UserInfoKey.sidebarItemID] ?? userInfo[UserInfoKey.feedIdentifier]) as? [String: String],
			  let sidebarItemID = SidebarItemIdentifier(userInfo: sidebarItemIDUserInfo),
			  let list = SmartFeedsController.shared.find(by: sidebarItemID) else {
			return false
		}

		selectList(list, revealList: false) {
			self.selectArticleInCurrentFeed(articleID)
		}
		return true
	}
}
