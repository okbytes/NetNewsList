//
//  MainWindowController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 8/1/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import os
import UserNotifications
import Articles
import Account
import RSCore

final class MainWindowController: NSWindowController, NSUserInterfaceValidations {
	static private let logger = Logger(subsystem: Logger.nnwSubsystem, category: "MainWindowController")

	private var activityManager = ActivityManager()

	private let windowAutosaveName = NSWindow.FrameAutosaveName("MainWindow")

	private static let detailViewMinimumWidth = 384
	private static let timelineHoldingPriority: Float = 255
	private static let toolbarIdentifier = "MainWindowToolbar"
	private var splitViewController: NSSplitViewController?
	private var timelineContainerViewController: TimelineContainerViewController?
	private var detailViewController: DetailViewController?
	private var restoreArticleWindowScrollY: CGFloat?

	// MARK: - NSWindowController

	convenience init() {
		self.init(windowNibName: "MainWindow")
	}

	override func windowDidLoad() {
		super.windowDidLoad()

		if let window = window {
			let point = NSPoint(x: 128, y: 64)
			let size = NSSize(width: 1345, height: 900)
			let minSize = NSSize(width: 600, height: 600)
			window.setPointAndSizeAdjustingForScreen(point: point, size: size, minimumSize: minSize)
		}

		let timelineContainerViewController = TimelineContainerViewController()
		timelineContainerViewController.delegate = self
		self.timelineContainerViewController = timelineContainerViewController

		detailViewController = DetailViewController()

		installSplitViewController()
		// Every window opens on the Queue.
		show(SmartFeedsController.shared.unreadFeed)

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
	}

	// MARK: - API

	func handle(_ response: UNNotificationResponse) {
		let userInfo = response.notification.request.content.userInfo
		guard let articlePathUserInfo = userInfo[UserInfoKey.articlePath] as? [AnyHashable: Any] else {
			return
		}
		revealArticle(for: articlePathUserInfo)
	}

	func handle(_ activity: NSUserActivity) {
		guard let articlePathUserInfo = activity.userInfo?[UserInfoKey.articlePath] as? [AnyHashable: Any] else {
			return
		}
		revealArticle(for: articlePathUserInfo)
	}

	func saveStateToUserDefaults() {
		let state = savableState()
		Self.logger.debug("MainWindowController: Saving state to UserDefaults: \(state)")
		let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
		AppDefaults.shared.secureWindowState = data
		// Don't save the frame in full screen — it would replace the saved windowed frame with the screen's frame.
		if let window, !window.styleMask.contains(.fullScreen) {
			window.saveFrame(usingName: windowAutosaveName)
		}
	}

	func restoreStateFromUserDefaults() {
		if let data = AppDefaults.shared.secureWindowState,
		   let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MainWindowState.self, from: data) {
			Self.logger.debug("MainWindowController: restoring state from UserDefaults: \(state)")
			window?.setFrameUsingName(windowAutosaveName, force: true)
			restoreState(from: state)
		}
	}

	// MARK: - Notifications

	@objc func unreadCountDidChange(_ note: Notification) {
		CoalescingQueue.standard.add(self, #selector(coalescedUpdateWindowTitle))
	}

	@objc func coalescedUpdateWindowTitle() {
		updateWindowTitle()
	}

	// MARK: - Toolbar

	@objc func makeToolbarValidate() {

		window?.toolbar?.validateVisibleItems()
	}

	// MARK: - NSUserInterfaceValidations

	public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {

		if item.action == #selector(retrySavingPage(_:)) || item.action == #selector(retrySavingLivePage(_:)) || item.action == #selector(deleteArticles(_:)) || item.action == #selector(delete(_:)) {
			return !(selectedArticles?.isEmpty ?? true)
		}

		if item.action == #selector(copyArticleURL(_:)) {
			return canCopyArticleURL()
		}

		if item.action == #selector(copyExternalURL(_:)) {
			return canCopyExternalURL()
		}

		if item.action == #selector(openArticleInBrowser(_:)) {
			return currentLink != nil
		}

		if item.action == #selector(toggleRead(_:)) {
			return validateToggleRead(item)
		}

		if item.action == #selector(gotoQueue(_:)) {
			return validateList(item, SmartFeedsController.shared.unreadFeed)
		}

		if item.action == #selector(gotoArchive(_:)) {
			return validateList(item, SmartFeedsController.shared.archiveFeed)
		}

		if item.action == #selector(sortArticlesByField(_:)) {
			return validateSortArticlesByField(item)
		}

		if item.action == #selector(sortArticlesAscending(_:)) {
			return validateSortDirection(item, direction: .orderedAscending)
		}

		if item.action == #selector(sortArticlesDescending(_:)) {
			return validateSortDirection(item, direction: .orderedDescending)
		}

		return true
	}

	// MARK: - Actions

	/// The space bar scrolls the article a page at a time and stops at the end.
	@IBAction func scrollArticle(_ sender: Any?) {
		guard let detailViewController else {
			return
		}
		Task { @MainActor in
			guard await detailViewController.canScrollDown() else {
				return
			}
			NSCursor.setHiddenUntilMouseMoves(true)
			detailViewController.scrollPageDown(sender)
		}
	}

	@IBAction func scrollUp(_ sender: Any?) {
		guard let detailViewController else {
			return
		}
		Task { @MainActor in
			let canScroll = await detailViewController.canScrollUp()
			if canScroll {
				NSCursor.setHiddenUntilMouseMoves(true)
				detailViewController.scrollPageUp(sender)
			}
		}
	}

	@IBAction func copyArticleURL(_ sender: Any?) {
		guard let articles = selectedArticles else {
			assertionFailure("Expected selectedArticles to be non-nil")
			return
		}
		let links = articles.compactMap { $0.preferredLink }
		if links.isEmpty {
			assertionFailure("Expected at least one link")
			return
		}

		URLPasteboardWriter.write(urlStrings: links, to: .general)
	}

	@IBAction func copyExternalURL(_ sender: Any?) {
		guard let articles = selectedArticles else {
			assertionFailure("Expected selectedArticles to be non-nil")
			return
		}
		let links = articles.compactMap { $0.externalLink }
		if links.isEmpty {
			assertionFailure("Expected at least one link")
			return
		}

		URLPasteboardWriter.write(urlStrings: links, to: .general)
	}

	@IBAction func openArticleInBrowser(_ sender: Any?) {
		if let link = currentLink {
			Browser.open(link)
		}
	}

	/// The b and Enter keys.
	@IBAction func openInBrowser(_ sender: Any?) {
		openArticleInBrowser(sender)
	}

	/// The Return key. There’s no in-app browser on the Mac.
	@objc func openInAppBrowser(_ sender: Any?) {
		openArticleInBrowser(sender)
	}

	@IBAction func toggleRead(_ sender: Any?) {
		currentTimelineViewController?.toggleReadStatusForSelectedArticles()
	}

	@IBAction func retrySavingPage(_ sender: Any?) {
		guard let articleIDs = selectedArticles?.map(\.articleID), !articleIDs.isEmpty else {
			return
		}
		ExtractionCoordinator.shared.retry(articleIDs: Set(articleIDs), usesLivePage: false)
	}

	@IBAction func retrySavingLivePage(_ sender: Any?) {
		guard let articleIDs = selectedArticles?.map(\.articleID), !articleIDs.isEmpty else {
			return
		}
		ExtractionCoordinator.shared.retry(articleIDs: Set(articleIDs), usesLivePage: true)
	}

	@IBAction func navigateToTimeline(_ sender: Any?) {
		currentTimelineViewController?.focus()
	}

	@IBAction func navigateToDetail(_ sender: Any?) {
		detailViewController?.focus()
	}

	@IBAction func gotoQueue(_ sender: Any?) {
		show(SmartFeedsController.shared.unreadFeed)
		currentTimelineViewController?.focus()
	}

	@IBAction func gotoArchive(_ sender: Any?) {
		show(SmartFeedsController.shared.archiveFeed)
		currentTimelineViewController?.focus()
	}

	/// Deletes the selected articles here and on every other device, after asking.
	@IBAction func deleteArticles(_ sender: Any?) {
		guard let articles = selectedArticles, let window else {
			return
		}
		ArticleDeletion.confirmAndDelete(articles, in: window)
	}

	/// Edit > Delete and the Delete key in the timeline.
	@IBAction func delete(_ sender: Any?) {
		deleteArticles(sender)
	}

	@IBAction func sortArticlesByField(_ sender: NSMenuItem) {
		// The menu item’s identifier is the ArticleSortKey raw value.
		guard let identifier = sender.identifier, let key = ArticleSortKey(rawValue: identifier.rawValue) else {
			return
		}
		timelineContainerViewController?.sortBy(key: key)
	}

	@IBAction func sortArticlesAscending(_ sender: Any?) {
		timelineContainerViewController?.setSortDirection(.orderedAscending)
	}

	@IBAction func sortArticlesDescending(_ sender: Any?) {
		timelineContainerViewController?.setSortDirection(.orderedDescending)
	}
}

// MARK: NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

	func window(_ window: NSWindow, willEncodeRestorableState coder: NSCoder) {
		let state = savableState()
		Self.logger.debug("MainWindowController: willEncodeRestorableState: \(state)")
		coder.encode(state, forKey: UserInfoKey.windowState)
	}

	func window(_ window: NSWindow, didDecodeRestorableState coder: NSCoder) {
		guard let state = coder.decodeObject(of: MainWindowState.self, forKey: UserInfoKey.windowState) else {
			Self.logger.debug("MainWindowController: failed to decode restorable state")
			return
		}
		Self.logger.debug("MainWindowController: didDecodeRestorableState: \(state)")
		restoreState(from: state)
	}

	func windowWillClose(_ notification: Notification) {
		Self.logger.debug("MainWindowController: windowWillClose")
		detailViewController?.stopMediaPlayback()
		appDelegate.removeMainWindow(self)
	}
}

// MARK: - TimelineContainerViewControllerDelegate

extension MainWindowController: TimelineContainerViewControllerDelegate {

	func timelineSelectionDidChange(_: TimelineContainerViewController, articles: [Article]?) {
		activityManager.invalidateReading()

		makeToolbarValidate()

		let detailState: DetailState
		if let articles = articles {
			if articles.count == 1 {
				activityManager.reading(feed: nil, article: articles.first)
				detailState = .article(articles.first!, restoreArticleWindowScrollY)
				restoreArticleWindowScrollY = nil
			} else {
				detailState = .multipleSelection
			}
		} else {
			detailState = .noSelection
		}

		detailViewController?.setState(detailState)
	}

	func timelineInvalidatedRestorationState(_: TimelineContainerViewController) {
		invalidateRestorableState()
	}

}

// MARK: - NSToolbarDelegate

extension NSToolbarItem.Identifier {
	static let listMenu = NSToolbarItem.Identifier("listMenu")
	static let addArticle = NSToolbarItem.Identifier("addArticle")
	static let markRead = NSToolbarItem.Identifier("markRead")
	static let openInBrowser = NSToolbarItem.Identifier("openInBrowser")
	static let listTrackingSeparator = NSToolbarItem.Identifier("listTrackingSeparator")
}

extension MainWindowController: NSToolbarDelegate {

	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

		switch itemIdentifier {

		case .listMenu:
			let toolbarItem = NSMenuToolbarItem(itemIdentifier: .listMenu)
			toolbarItem.image = Assets.Images.listMenu
			toolbarItem.showsIndicator = false
			let description = NSLocalizedString("Lists", comment: "Toolbar menu that switches between the Queue and the Archive")
			toolbarItem.toolTip = description
			toolbarItem.label = description
			toolbarItem.menu = makeListMenu()
			return toolbarItem

		case .addArticle:
			let title = NSLocalizedString("Add Article", comment: "Add Article")
			return buildToolbarButton(.addArticle, title, Assets.Images.addNewSidebarItem, "showAddArticleWindow:")

		case .markRead:
			let title = NSLocalizedString("Archive", comment: "command")
			return buildToolbarButton(.markRead, title, Assets.Images.archive, "toggleRead:")

		case .openInBrowser:
			let title = NSLocalizedString("Open in Browser", comment: "Command")
			return buildToolbarButton(.openInBrowser, title, Assets.Images.openInBrowser, "openArticleInBrowser:")

		case .listTrackingSeparator:
			// Keeps Add Article and the list menu over the list, and the article buttons over the article.
			guard let splitView = splitViewController?.splitView else {
				return nil
			}
			return NSTrackingSeparatorToolbarItem(identifier: .listTrackingSeparator, splitView: splitView, dividerIndex: 0)

		default:
			return nil
		}
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		toolbarDefaultItemIdentifiers(toolbar)
	}

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[
			.addArticle,
			.listMenu,
			.listTrackingSeparator,
			.flexibleSpace,
			.markRead,
			.openInBrowser
		]
	}
}

// MARK: - Private

private extension MainWindowController {

	// MARK: - Layout

	/// Puts the list and the article view side by side in the window’s split view, then adds the toolbar.
	func installSplitViewController() {
		guard let window, let timelineContainerViewController, let detailViewController else {
			return
		}

		let savedFrame = window.frame
		let splitViewController = makeSplitViewController(timeline: timelineContainerViewController, detail: detailViewController)
		self.splitViewController = splitViewController
		window.contentViewController = splitViewController
		if window.frame != savedFrame {
			window.setFrame(savedFrame, display: false)
		}
		window.toolbar = makeToolbar()

		currentTimelineViewController?.focus()
		window.recalculateKeyViewLoop()
	}

	func makeSplitViewController(timeline: TimelineContainerViewController, detail: DetailViewController) -> NSSplitViewController {
		let splitViewController = NSSplitViewController()
		splitViewController.splitView.isVertical = true
		splitViewController.splitView.dividerStyle = .thin
		splitViewController.splitView.wantsLayer = true

		let timelineItem = NSSplitViewItem(contentListWithViewController: timeline)
		timelineItem.holdingPriority = NSLayoutConstraint.Priority(Self.timelineHoldingPriority)

		let detailItem = NSSplitViewItem(viewController: detail)
		detailItem.minimumThickness = CGFloat(Self.detailViewMinimumWidth)
		if #unavailable(macOS 26.0) {
			detailItem.titlebarSeparatorStyle = .line
		}

		splitViewController.splitViewItems = [timelineItem, detailItem]
		return splitViewController
	}

	/// The toolbar can’t be customized, so it always has the default items.
	func makeToolbar() -> NSToolbar {
		let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
		toolbar.allowsUserCustomization = false
		toolbar.autosavesConfiguration = false
		toolbar.displayMode = .iconOnly
		toolbar.delegate = self
		return toolbar
	}

	var currentTimelineViewController: TimelineViewController? {
		timelineContainerViewController?.timelineViewController
	}

	var selectedArticles: [Article]? {
		return currentTimelineViewController?.selectedArticles
	}

	var oneSelectedArticle: Article? {
		if let articles = selectedArticles {
			return articles.count == 1 ? articles[0] : nil
		}
		return nil
	}

	var currentLink: String? {
		return oneSelectedArticle?.preferredLink
	}

	// MARK: - Lists

	/// The list the window shows: the Queue (`unreadFeed`) or the Archive.
	var currentList: PseudoFeed? {
		currentTimelineViewController?.representedObjects?.first as? PseudoFeed
	}

	/// Shows the Queue or the Archive in the timeline.
	func show(_ list: PseudoFeed) {
		timelineContainerViewController?.setRepresentedObjects([list])
		updateWindowTitle()
	}

	/// Handoff and notifications name an article: show the list it’s in, and select it.
	func revealArticle(for articlePathUserInfo: [AnyHashable: Any]) {
		let smartFeeds = SmartFeedsController.shared
		guard let articleID = articlePathUserInfo[ArticlePathKey.articleID] as? String,
			  let article = AccountManager.shared.fetchArticles(.articleIDs([articleID])).first else {
			show(smartFeeds.unreadFeed)
			return
		}
		show(smartFeeds.list(for: article))
		currentTimelineViewController?.goToDeepLink(for: articlePathUserInfo)
	}

	// MARK: - State Restoration

	func savableState() -> MainWindowState {
		let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
		return MainWindowState(isFullScreen: isFullScreen,
							   timelineWidth: timelineWidth,
							   timelineWindowState: timelineContainerViewController?.windowState,
							   detailWindowState: detailViewController?.windowState)
	}

	var timelineWidth: Int {
		guard let timelineView = splitViewController?.splitView.arrangedSubviews.first else {
			return 0
		}
		return Int(floor(timelineView.frame.width))
	}

	/// Restores the window’s size, the list’s width, the sort and the selected article. The window stays on the Queue.
	func restoreState(from state: MainWindowState) {
		if state.isFullScreen {
			// Defer the toggle — during launch the window isn't on screen yet,
			// and AppKit ignores toggleFullScreen for windows not yet on screen.
			Task { @MainActor in
				guard let window = self.window, !window.styleMask.contains(.fullScreen) else {
					return
				}
				window.toggleFullScreen(nil)
			}
		}
		if state.timelineWidth > 0 {
			splitViewController?.splitView.setPosition(CGFloat(state.timelineWidth), ofDividerAt: 0)
		}

		// The saved scroll position belongs to the restored article, and to no other.
		restoreArticleWindowScrollY = state.detailWindowState?.windowScrollY
		timelineContainerViewController?.restoreState(from: state.timelineWindowState)
		restoreArticleWindowScrollY = nil
	}

	// MARK: - Command Validation

	func canCopyArticleURL() -> Bool {
		guard let selectedArticles else {
			return false
		}

		for article in selectedArticles {
			if article.preferredLink != nil {
				return true
			}
		}
		return false
	}

	func canCopyExternalURL() -> Bool {
		guard let selectedArticles else {
			return false
		}

		for article in selectedArticles {
			if article.externalLink != nil {
				return true
			}
		}
		return false
	}

	func validateToggleRead(_ item: NSValidatedUserInterfaceItem) -> Bool {

		let validationStatus = currentTimelineViewController?.markReadCommandStatus() ?? .canDoNothing
		let markingRead: Bool
		let result: Bool

		switch validationStatus {
		case .canMark:
			markingRead = true
			result = true
		case .canUnmark:
			markingRead = false
			result = true
		case .canDoNothing:
			markingRead = true
			result = false
		}

		let commandName = markingRead ? NSLocalizedString("Archive", comment: "Command") : NSLocalizedString("Move to Queue", comment: "Command")

		if let toolbarItem = item as? NSToolbarItem {
			toolbarItem.toolTip = commandName
			// Text Only toolbar mode shows the label and menu form representation, so they need to track state too.
			let shortName = markingRead ? NSLocalizedString("Archive", comment: "command") : NSLocalizedString("Move to Queue", comment: "command")
			toolbarItem.label = shortName
			toolbarItem.menuFormRepresentation?.title = shortName
		}

		if let menuItem = item as? NSMenuItem {
			menuItem.title = commandName
		}

		if let toolbarItem = item as? NSToolbarItem, let button = toolbarItem.view as? NSButton {
			button.image = markingRead ? Assets.Images.archive : Assets.Images.moveToQueue
		}

		return result
	}

	/// Go › Queue and Go › Archive are checked when their list is showing.
	func validateList(_ item: NSValidatedUserInterfaceItem, _ list: PseudoFeed) -> Bool {
		if let menuItem = item as? NSMenuItem {
			menuItem.state = currentList === list ? .on : .off
		}
		return true
	}

	func validateSortArticlesByField(_ item: NSValidatedUserInterfaceItem) -> Bool {
		guard let sortParameters = timelineContainerViewController?.sortParameters, let menuItem = item as? NSMenuItem, let identifier = menuItem.identifier, let key = ArticleSortKey(rawValue: identifier.rawValue) else {
			return false
		}
		menuItem.state = sortParameters.key == key ? .on : .off
		return true
	}

	/// The direction items are worded for the current field: Oldest/Newest for date, A to Z for text.
	func validateSortDirection(_ item: NSValidatedUserInterfaceItem, direction: ComparisonResult) -> Bool {
		guard let sortParameters = timelineContainerViewController?.sortParameters, let menuItem = item as? NSMenuItem else {
			return false
		}
		menuItem.title = sortParameters.key.localizedDirectionTitle(ascending: direction == .orderedAscending)
		menuItem.state = sortParameters.direction == direction ? .on : .off
		return true
	}

	// MARK: - Misc.

	func updateWindowTitle() {
		guard let list = currentList else {
			window?.title = appName
			window?.subtitle = ""
			return
		}
		window?.title = list.nameForDisplay

		// Only the Queue has a count. Archive is everything already read, so it has none.
		let queue = SmartFeedsController.shared.unreadFeed
		guard list === queue else {
			window?.subtitle = ""
			return
		}
		let localizedLabel = NSLocalizedString("%d in Queue", comment: "Window subtitle: the number of articles in the Queue")
		window?.subtitle = NSString.localizedStringWithFormat(localizedLabel as NSString, queue.unreadCount) as String
	}

	func buildToolbarButton(_ itemIdentifier: NSToolbarItem.Identifier, _ title: String, _ image: NSImage, _ selector: String) -> NSToolbarItem {
		let toolbarItem = RSToolbarItem(itemIdentifier: itemIdentifier)
		toolbarItem.autovalidates = true

		let button = NSButton()
		button.bezelStyle = .texturedRounded
		button.image = image
		button.imageScaling = .scaleProportionallyDown
		button.action = Selector((selector))

		toolbarItem.view = button
		toolbarItem.toolTip = title
		toolbarItem.label = title
		// A menu form representation keeps view-based items working in the toolbar's Text Only mode and overflow menu.
		toolbarItem.menuFormRepresentation = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: "")
		return toolbarItem
	}

	/// Queue and Archive, checked by validateList like the Go menu’s items.
	func makeListMenu() -> NSMenu {
		let smartFeeds = SmartFeedsController.shared
		let menu = NSMenu()
		let queueItem = NSMenuItem(title: smartFeeds.unreadFeed.nameForDisplay, action: #selector(gotoQueue(_:)), keyEquivalent: "1")
		queueItem.target = self
		menu.addItem(queueItem)
		let archiveItem = NSMenuItem(title: smartFeeds.archiveFeed.nameForDisplay, action: #selector(gotoArchive(_:)), keyEquivalent: "2")
		archiveItem.target = self
		menu.addItem(archiveItem)
		return menu
	}
}
