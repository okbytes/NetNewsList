//
//  TimelineViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import Articles
import Account
import Images

@MainActor protocol TimelineDelegate: AnyObject {
	func timelineSelectionDidChange(_: TimelineViewController, selectedArticles: [Article]?)
	func timelineInvalidatedRestorationState(_: TimelineViewController)
	func timelineRequestedSortChange(_: TimelineViewController, parameters: ArticleSortParameters)
}

enum TimelineShowFeedName: Sendable {
	case none
	case byline
	case feed
}

final class TimelineViewController: NSViewController, UndoableCommandRunner, UnreadCountProvider {

	@IBOutlet var tableView: TimelineTableView!

	var sharingServicePickerDelegate: NSSharingServicePickerDelegate?

	/// Queue and Archive each fetch exactly what belongs in them, so nothing is filtered by read status.
	/// The shared fetch code still takes a per-list read filter table; this one is always empty.
	private static let noReadFilters = [SidebarItemIdentifier: Bool]()

	var representedObjects: [AnyObject]? {
		didSet {
			if !representedObjectArraysAreEqual(oldValue, representedObjects) {
				unreadCount = 0

				selectionDidChange(nil)
				if showsSearchResults {
					fetchAndReplaceArticlesAsync()
				} else {
					fetchAndReplaceArticlesSync()
					if articles.count > 0 {
						tableView.scrollRowToVisible(0)
					}
					updateUnreadCount()
				}
			}
		}
	}

	var windowState: TimelineWindowState {
		guard let path = oneSelectedArticle?.pathUserInfo else {
			return TimelineWindowState(sortParameters: sortParameters)
		}
		return TimelineWindowState(selectedAccountID: path[ArticlePathKey.accountID] as? String,
								   selectedArticleID: path[ArticlePathKey.articleID] as? String,
								   sortParameters: sortParameters)
	}
	weak var delegate: TimelineDelegate?
	var sharingServiceDelegate: NSSharingServiceDelegate?

	var showsSearchResults = false
	var selectedArticles: [Article] {
		return articles.articlesForIndexes(tableView.selectedRowIndexes)
	}

	var hasAtLeastOneSelectedArticle: Bool {
		return tableView.selectedRow != -1
	}

	var articles = ArticleArray() {
		didSet {
			defer {
				updateUnreadCount()
			}

			if articles == oldValue {
				return
			}

			if articles.representSameArticlesInSameOrder(as: oldValue) {
				// When the array is the same — same articles, same order —
				// but some data in some of the articles may have changed.
				// Just reload visible cells in this case: don’t call reloadData.
				articleRowMap = [String: [Int]]()
				reloadVisibleCells()
				return
			}

			if let representedObjects = representedObjects, representedObjects.count == 1 && representedObjects.first is Feed {
				showFeedNames = {
					for article in articles {
						if !article.byline().isEmpty {
							return .byline
						}
					}
					return .none
				}()
			} else {
				showFeedNames = .feed
			}

			articleRowMap = [String: [Int]]()
			tableView.reloadData()
			IconImageCache.shared.prefetchImagesForArticles(articles)
		}
	}

	var unreadCount: Int = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
			}
		}
	}

	var undoableCommands = [UndoableCommand]()

	private var fetchSerialNumber = 0
	private let fetchRequestQueue = FetchRequestQueue()
	private var exceptionArticleFetcher: ArticleFetcher?
	private var articleRowMap = [String: [Int]]() // articleID: rowIndex
	private var cellAppearance: TimelineCellAppearance!
	private var cellAppearanceWithIcon: TimelineCellAppearance!
	private var showFeedNames: TimelineShowFeedName = .none {
		didSet {
			if showFeedNames != oldValue {
				updateShowIcons()
				updateTableViewRowHeight()
				reloadVisibleCells()
			}
		}
	}

	private var showIcons = false
	private var currentRowHeight: CGFloat = 0.0

	private var didRegisterForNotifications = false
	static let fetchAndMergeArticlesQueue = CoalescingQueue(name: "Fetch and Merge Articles", interval: 0.5, maxInterval: 2.0)

	// Owned by the window’s TimelineContainerViewController.
	// Before the view loads there is nothing to re-sort — the first fetch uses the current value.
	var sortParameters = ArticleSortParameters.newestFirst {
		didSet {
			if isViewLoaded && sortParameters != oldValue {
				sortParametersDidChange()
				applySortDescriptorsToTableView()
			}
		}
	}
	// Also owned by the container, which pushes the current value before and after the view loads.
	var layout = TimelineLayout.standard {
		didSet {
			if isViewLoaded && layout != oldValue {
				layoutDidChange()
			}
		}
	}
	// The nib’s single column, kept so standard layout can put it back.
	var standardColumn: NSTableColumn?
	// Set while columns are added and autosaved state is restored, which fires sortDescriptorsDidChange.
	var isConfiguringTableColumns = false
	private var fontSize: FontSize = AppDefaults.shared.timelineFontSize {
		didSet {
			if fontSize != oldValue {
				fontSizeDidChange()
			}
		}
	}

	private struct ArticleIdentityKey: Equatable {
		let accountID: String
		let articleID: String
	}

	private var previouslySelectedArticleKeys: [ArticleIdentityKey]?

	private var oneSelectedArticle: Article? {
		return selectedArticles.count == 1 ? selectedArticles.first : nil
	}

	private let keyboardDelegate = TimelineKeyboardDelegate()
	private var timelineShowsSeparatorsObserver: NSKeyValueObservation?

	convenience init(delegate: TimelineDelegate) {
		self.init(nibName: "TimelineTableView", bundle: nil)
		self.delegate = delegate
	}

	override func viewDidLoad() {
		cellAppearance = TimelineCellAppearance(showIcon: false, fontSize: fontSize)
		cellAppearanceWithIcon = TimelineCellAppearance(showIcon: true, fontSize: fontSize)

		updateRowHeights()
		tableView.target = self
		tableView.doubleAction = #selector(openArticleInBrowser(_:))
		tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
		tableView.registerForDraggedTypes(DroppedWebPages.pasteboardTypes)
		tableView.keyboardDelegate = keyboardDelegate
		tableView.style = .inset

		standardColumn = tableView.tableColumns.first
		configureTableView(for: layout)
		updateShowIcons()

		if !didRegisterForNotifications {
			NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .ExtractionStateDidChange, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(feedIconDidBecomeAvailable(_:)), name: .feedIconDidBecomeAvailable, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(avatarDidBecomeAvailable(_:)), name: .AvatarDidBecomeAvailable, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(faviconDidBecomeAvailable(_:)), name: .FaviconDidBecomeAvailable, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(accountStateDidChange(_:)), name: .AccountStateDidChange, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(accountsDidChange(_:)), name: .UserDidAddAccount, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(userDidDeleteAccount(_:)), name: .UserDidDeleteAccount, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(accountDidDeleteArticles(_:)), name: .AccountDidDeleteArticles, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(containerChildrenDidChange(_:)), name: .ChildrenDidChange, object: nil)
			NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in
					self?.userDefaultsDidChange()
				}
			}
			didRegisterForNotifications = true
		}

		sharingServicePickerDelegate = SharingServicePickerDelegate(self.view.window)
	}

	override func viewDidAppear() {
		sharingServiceDelegate = SharingServiceDelegate(self.view.window)
	}

	// MARK: - API

	func markAllAsRead() {
		guard let undoManager = undoManager, let markReadCommand = MarkStatusCommand(initialArticles: articles, markingRead: true, undoManager: undoManager) else {
			return
		}
		runCommand(markReadCommand)
	}

	func canMarkAllAsRead() -> Bool {
		return articles.canMarkAllAsRead()
	}

	func canMarkSelectedArticlesAsRead() -> Bool {
		return selectedArticles.canMarkAllAsRead()
	}

	func representsThisObjectOnly(_ object: AnyObject) -> Bool {
		guard let representedObjects = representedObjects else {
			return false
		}
		if representedObjects.count != 1 {
			return false
		}
		return representedObjects.first! === object
	}

	// MARK: State Restoration

	func restoreState(from state: TimelineWindowState) {
		if let selectedAccountID = state.selectedAccountID,
		   let account = AccountManager.shared.existingAccount(accountID: selectedAccountID),
		   let selectedArticleID = state.selectedArticleID {

			exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: selectedArticleID)
			fetchAndReplaceArticlesSync()

			if let selectedIndex = articles.firstIndex(where: { $0.articleID == selectedArticleID }) {
				tableView.selectRow(selectedIndex)
				DispatchQueue.main.async {
					self.tableView.scrollTo(row: selectedIndex)
				}
				focus()
			}
		} else {
			fetchAndReplaceArticlesSync()
		}
	}

	/// Restore state using legacy state restoration data.
	///
	/// TODO: Delete for NetNewsWire 7.
	func restoreLegacyState(from state: [AnyHashable: Any]) {
		if let articlePathUserInfo = state[UserInfoKey.articlePath] as? [AnyHashable: Any],
			let accountID = articlePathUserInfo[ArticlePathKey.accountID] as? String,
			let account = AccountManager.shared.existingAccount(accountID: accountID),
			let articleID = articlePathUserInfo[ArticlePathKey.articleID] as? String {

			exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: articleID)
			fetchAndReplaceArticlesSync()

			if let selectedIndex = articles.firstIndex(where: { $0.articleID == articleID }) {
				tableView.selectRow(selectedIndex)
				DispatchQueue.main.async {
					self.tableView.scrollTo(row: selectedIndex)
				}
				focus()
			}
		} else {
			fetchAndReplaceArticlesSync()
		}
	}

	// MARK: - Actions

	@objc func openArticleInBrowser(_ sender: Any?) {
		if let link = oneSelectedArticle?.preferredLink {
			Browser.open(link, invertPreference: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
		}
	}

	@IBAction func toggleStatusOfSelectedArticles(_ sender: Any?) {
		guard !selectedArticles.isEmpty else {
			return
		}
		let articles = selectedArticles
		let status = articles.first!.status
		let markAsRead = !status.read

		if markAsRead {
			markSelectedArticlesAsRead(sender)
		} else {
			markSelectedArticlesAsUnread(sender)
		}
	}

	@IBAction func markSelectedArticlesAsRead(_ sender: Any?) {
		guard let undoManager = undoManager, let markReadCommand = MarkStatusCommand(initialArticles: selectedArticles, markingRead: true, undoManager: undoManager) else {
			return
		}
		runCommand(markReadCommand)
	}

	@IBAction func markSelectedArticlesAsUnread(_ sender: Any?) {
		guard let undoManager = undoManager, let markUnreadCommand = MarkStatusCommand(initialArticles: selectedArticles, markingRead: false, undoManager: undoManager) else {
			return
		}
		runCommand(markUnreadCommand)
	}

	@IBAction func copy(_ sender: Any?) {
		NSPasteboard.general.copyObjects(selectedArticles)
	}

	@IBAction func selectNextUp(_ sender: Any?) {
		guard let lastSelectedRow = tableView.selectedRowIndexes.last else {
			return
		}

		let nextRowIndex = lastSelectedRow - 1
		if nextRowIndex <= 0 {
			tableView.scrollTo(row: 0, extraHeight: 0)
		}

		tableView.selectRow(nextRowIndex)

		let followingRowIndex = nextRowIndex - 1
		if followingRowIndex < 0 {
			return
		}

		tableView.scrollToRowIfNotVisible(followingRowIndex)

	}

	@IBAction func selectNextDown(_ sender: Any?) {
		guard let firstSelectedRow = tableView.selectedRowIndexes.first else {
			return
		}

		let tableMaxIndex = tableView.numberOfRows - 1
		let nextRowIndex = firstSelectedRow + 1
		if nextRowIndex >= tableMaxIndex {
			tableView.scrollTo(row: tableMaxIndex, extraHeight: 0)
		}

		tableView.selectRow(nextRowIndex)

		let followingRowIndex = nextRowIndex + 1
		if followingRowIndex > tableMaxIndex {
			return
		}

		tableView.scrollToRowIfNotVisible(followingRowIndex)

	}

	func toggleReadStatusForSelectedArticles() {
		// If any one of the selected articles is unread, then mark them as read.
		// If all articles are read, then mark them as unread them.

		let commandStatus = markReadCommandStatus()
		let markingRead: Bool
		switch commandStatus {
		case .canMark:
			markingRead = true
		case .canUnmark:
			markingRead = false
		case .canDoNothing:
			return
		}

		guard let undoManager = undoManager, let markReadCommand = MarkStatusCommand(initialArticles: selectedArticles, markingRead: markingRead, undoManager: undoManager) else {
			return
		}

		runCommand(markReadCommand)
	}

	func markReadCommandStatus() -> MarkCommandValidationStatus {
		let articles = selectedArticles

		if articles.anyArticleIsUnread() {
			return .canMark
		}

		if articles.anyArticleIsReadAndCanMarkUnread() {
			return .canUnmark
		}

		return .canDoNothing
	}

	func markOlderArticlesRead() {
		markOlderArticlesRead(selectedArticles)
	}

	func markOlderArticlesRead(_ selectedArticles: [Article]) {
		// Mark articles older than the selectedArticles(s) as read.

		var cutoffDate: Date?
		for article in selectedArticles {
			if cutoffDate == nil {
				cutoffDate = article.logicalDatePublished
			} else if cutoffDate! > article.logicalDatePublished {
				cutoffDate = article.logicalDatePublished
			}
		}
		if cutoffDate == nil {
			return
		}

		let articlesToMark = articles.filter { $0.logicalDatePublished < cutoffDate! }
		if articlesToMark.isEmpty {
			return
		}

		guard let undoManager = undoManager, let markReadCommand = MarkStatusCommand(initialArticles: articlesToMark, markingRead: true, undoManager: undoManager) else {
			return
		}
		runCommand(markReadCommand)
	}

	// MARK: - Navigation

	func goToDeepLink(for userInfo: [AnyHashable: Any]) {
		guard let articleID = userInfo[ArticlePathKey.articleID] as? String else { return }

		guard let ix = articles.firstIndex(where: { $0.articleID == articleID }) else {	return }

		NSCursor.setHiddenUntilMouseMoves(true)
		tableView.selectRow(ix)
		tableView.scrollTo(row: ix)
	}

	func focus() {
		guard let window = tableView.window else {
			return
		}

		window.makeFirstResponderUnlessDescendantIsFirstResponder(tableView)
		if !hasAtLeastOneSelectedArticle && articles.count > 0 {
			tableView.selectRowAndScrollToVisible(0)
		}
	}

	// MARK: - Notifications

	@objc func statusesDidChange(_ note: Notification) {
		guard let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String> else {
			return
		}
		reloadVisibleCells(for: articleIDs)
		updateUnreadCount()
		keepOnlyListMembers(changed: articleIDs)
	}

	/// Queue shows only articles not yet archived and Archive only archived ones. An article
	/// whose status changed leaves the list it no longer belongs in, and the row that takes
	/// its place is selected, as in Mail; one that now belongs (undo, or a change from another
	/// device) is fetched in.
	private func keepOnlyListMembers(changed articleIDs: Set<String>) {
		let smartFeeds = SmartFeedsController.shared
		guard representedObjects?.count == 1, let list = representedObjects?.first,
			  list === smartFeeds.unreadFeed || list === smartFeeds.archiveFeed else {
			return
		}
		let leavingIDs = Set(articles.filter { articleIDs.contains($0.articleID) && smartFeeds.list(for: $0) !== list }.map(\.articleID))
		if !leavingIDs.isEmpty {
			let selectedRow = tableView.selectedRow
			let selectionLeaves = selectedArticles.contains { leavingIDs.contains($0.articleID) }
			let remaining = Set(articles.filter { !leavingIDs.contains($0.articleID) })
			if selectionLeaves {
				replaceArticles(with: remaining)
				let row = min(selectedRow, articles.count - 1)
				if row >= 0 {
					tableView.selectRowAndScrollToVisible(row)
				}
			} else {
				performBlockAndRestoreSelection {
					replaceArticles(with: remaining)
				}
			}
		}
		if articleIDs.contains(where: { articleID in !articles.contains { $0.articleID == articleID } }) {
			queueFetchAndMergeArticles()
		}
	}

	@objc func feedIconDidBecomeAvailable(_ note: Notification) {
		guard showIcons, let feed = note.userInfo?[UserInfoKey.feed] as? Feed else {
			return
		}
		let indexesToReload = tableView.indexesOfAvailableRowsPassingTest { (row) -> Bool in
			guard let article = articles.articleAtRow(row) else {
				return false
			}
			return feed == article.feed
		}
		if let indexesToReload = indexesToReload {
			reloadCells(for: indexesToReload)
		}
	}

	@objc func avatarDidBecomeAvailable(_ note: Notification) {
		guard showIcons, let avatarURL = note.userInfo?[UserInfoKey.url] as? String else {
			return
		}

		let indexesToReload = tableView.indexesOfAvailableRowsPassingTest { (row) -> Bool in
			guard let article = articles.articleAtRow(row), let authors = article.authors, !authors.isEmpty else {
				return false
			}
			for author in authors {
				if author.avatarURL == avatarURL {
					return true
				}
			}
			return false
		}
		if let indexesToReload = indexesToReload {
			reloadCells(for: indexesToReload)
		}
	}

	/// Site favicons arrive one site at a time; the visible rows ask again.
	@objc func faviconDidBecomeAvailable(_ note: Notification) {
		guard showIcons else {
			return
		}
		if let indexesToReload = tableView.indexesOfAvailableRowsPassingTest({ _ in true }) {
			reloadCells(for: indexesToReload)
		}
	}

	@objc func accountDidDownloadArticles(_ note: Notification) {
		guard let feeds = note.userInfo?[Account.UserInfoKey.feeds] as? Set<Feed> else {
			return
		}

		let shouldFetchAndMergeArticles = representedObjectsContainsAnyFeed(feeds) || representedObjectsContainsAnyPseudoFeed()
		if shouldFetchAndMergeArticles {
			queueFetchAndMergeArticles()
		}
	}

	@objc func accountStateDidChange(_ note: Notification) {
		if representedObjectsContainsAnyPseudoFeed() {
			fetchAndReplacePreservingSelectionAsync()
		}
	}

	@objc func accountsDidChange(_ note: Notification) {
		if representedObjectsContainsAnyPseudoFeed() {
			fetchAndReplacePreservingSelectionAsync()
		}
	}

	@objc func userDidDeleteAccount(_ note: Notification) {
		undoManager?.removeAllActions() // Undo stack may contain actions for the deleted account.
		if representedObjectsContainsAnyPseudoFeed() {
			fetchAndReplacePreservingSelectionAsync()
		}
	}

	/// Deleted articles leave the timeline at once. A fetch-and-merge would keep them.
	@objc func accountDidDeleteArticles(_ note: Notification) {
		guard let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String>,
			  articles.contains(where: { articleIDs.contains($0.articleID) }) else {
			return
		}
		// Undo can't bring a deleted article back.
		undoManager?.removeAllActions()
		let remaining = Set(articles.filter { !articleIDs.contains($0.articleID) })
		performBlockAndRestoreSelection {
			replaceArticles(with: remaining)
		}
	}

	@objc func containerChildrenDidChange(_ note: Notification) {
		if representedObjectsContainsAnyPseudoFeed() || representedObjectsContainAnyFolder() {
			// Merge, don't replace — replacing drops articles read this session
			// from All Unread. Matches iOS.
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/3832>
			queueFetchAndMergeArticles()
		}
	}

	@MainActor func userDefaultsDidChange() {
		fontSize = AppDefaults.shared.timelineFontSize
	}

	/// The one place the row height is set — it depends on the layout and the font size.
	func updateTableViewRowHeight() {
		tableView.rowHeight = layout == .column ? columnRowHeight() : currentRowHeight
	}

	// MARK: - Reloading Data

	private func cellForRowView(_ rowView: NSView) -> NSView? {
		for oneView in rowView.subviews where oneView is TimelineTableCellView {
			return oneView
		}
		return nil
	}

	private func reloadVisibleCells() {
		guard let indexes = tableView.indexesOfAvailableRows() else {
			return
		}
		reloadVisibleCells(for: indexes)
	}

	private func reloadVisibleCells(for articles: [Article]) {
		reloadVisibleCells(for: Set(articles.articleIDs()))
	}

	private func reloadVisibleCells(for articles: Set<Article>) {
		reloadVisibleCells(for: articles.articleIDs())
	}

	private func reloadVisibleCells(for articleIDs: Set<String>) {
		if articleIDs.isEmpty {
			return
		}
		let indexes = indexesForArticleIDs(articleIDs)
		reloadVisibleCells(for: indexes)
	}

	private func reloadVisibleCells(for indexes: IndexSet) {
		let indexesToReload = tableView.indexesOfAvailableRowsPassingTest { (row) -> Bool in
			return indexes.contains(row)
		}
		if let indexesToReload = indexesToReload {
			reloadCells(for: indexesToReload)
		}
	}

	private func reloadCells(for indexes: IndexSet) {
		if indexes.isEmpty {
			return
		}
		tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
	}

	// MARK: - Cell Configuring

	private func calculateRowHeight() -> CGFloat {
		let longTitle = "But I must explain to you how all this mistaken idea of denouncing pleasure and praising pain was born and I will give you a complete account of the system, and expound the actual teachings of the great explorer of the truth, the master-builder of human happiness. No one rejects, dislikes, or avoids pleasure itself, because it is pleasure, but because those who do not know how to pursue pleasure rationally encounter consequences that are extremely painful. Nor again is there anyone who loves or pursues or desires to obtain pain of itself, because it is pain, but because occasionally circumstances occur in which toil and pain can procure him some great pleasure. To take a trivial example, which of us ever undertakes laborious physical exercise, except to obtain some advantage from it? But who has any right to find fault with a man who chooses to enjoy a pleasure that has no annoying consequences, or one who avoids a pain that produces no resultant pleasure?"
		let prototypeID = "prototype"
		let status = ArticleStatus(articleID: prototypeID, read: false, starred: false, dateArrived: Date())
		let prototypeArticle = Article(accountID: prototypeID, articleID: prototypeID, feedID: prototypeID, uniqueID: prototypeID, title: longTitle, contentHTML: nil, contentText: nil, markdown: nil, url: nil, externalURL: nil, summary: nil, imageURL: nil, datePublished: nil, dateModified: nil, authors: nil, status: status)

		let prototypeCellData = TimelineCellData(article: prototypeArticle, showFeedName: .feed, feedName: "Prototype Feed Name", byline: nil, iconImage: nil, showIcon: false)
		let height = TimelineCellLayout.height(for: 100, cellData: prototypeCellData, appearance: cellAppearance)
		return height
	}

	private func updateRowHeights() {
		currentRowHeight = calculateRowHeight()
		updateTableViewRowHeight()
	}

	@objc func fetchAndMergeArticles() {
		guard let representedObjects = representedObjects else {
			return
		}

		fetchUnsortedArticlesAsync(for: representedObjects) { [weak self] (unsortedArticles) in
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
			}
			strongSelf.performBlockAndRestoreSelection {
				strongSelf.replaceArticles(with: updatedArticles)
			}
		}
	}
}

// MARK: - NSMenuDelegate

extension TimelineViewController: NSMenuDelegate {

	public func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		guard let contextualMenu = contextualMenuForClickedRows() else {
			return
		}
		menu.takeItems(from: contextualMenu)
	}
}

// MARK: - NSUserInterfaceValidations

extension TimelineViewController: NSUserInterfaceValidations {

	func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
		if item.action == #selector(openArticleInBrowser(_:)) {
			if let item = item as? NSMenuItem, item.keyEquivalentModifierMask.contains(.shift) {
				item.title = Browser.titleForOpenInBrowserInverted
			}

			let currentLink = oneSelectedArticle?.preferredLink
			return currentLink != nil
		}

		if item.action == #selector(copy(_:)) {
			return NSPasteboard.general.canCopyAtLeastOneObject(selectedArticles)
		}

		return true
	}
}

// MARK: - NSTableViewDataSource

extension TimelineViewController: NSTableViewDataSource {
	func numberOfRows(in tableView: NSTableView) -> Int {
		return articles.count
	}

	func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
		return articles.articleAtRow(row) ?? nil
	}

	/// A web address dropped on the timeline is saved. Articles dragged within the timeline aren't.
	func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
		guard (info.draggingSource as? NSTableView) !== tableView, !DroppedWebPages.pages(on: info.draggingPasteboard).isEmpty else {
			return []
		}
		tableView.setDropRow(-1, dropOperation: .on)
		return .copy
	}

	func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
		DroppedWebPages.save(DroppedWebPages.pages(on: info.draggingPasteboard))
	}

	func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
		guard let article = articles.articleAtRow(row) else {
			return nil
		}
		return ArticlePasteboardWriter(article: article)
	}

	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		// Keeping -[NSTableViewDelegate tableView:heightOfRow:] implemented fixes
		// an issue that the bottom inset of NSTableView disappears on macOS Monterey.
		return tableView.rowHeight
	}
}

// MARK: - NSTableViewDelegate

extension TimelineViewController: NSTableViewDelegate {
	private static let rowViewIdentifier = NSUserInterfaceItemIdentifier(rawValue: "timelineRow")

	func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
		if layout == .column {
			// The standard row view suits column layout. TimelineTableRowView only knows the standard cell.
			return nil
		}
		if let rowView: TimelineTableRowView = tableView.makeView(withIdentifier: TimelineViewController.rowViewIdentifier, owner: nil) as? TimelineTableRowView {
			return rowView
		}
		let rowView = TimelineTableRowView()
		rowView.identifier = TimelineViewController.rowViewIdentifier
		return rowView
	}

	private static let timelineCellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "timelineCell")

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		if layout == .column {
			return columnCellView(for: tableColumn, row: row)
		}

		func configure(_ cell: TimelineTableCellView) {
			cell.cellAppearance = showIcons ? cellAppearanceWithIcon : cellAppearance
			if let article = articles.articleAtRow(row) {
				configureTimelineCell(cell, article: article)
			} else {
				makeTimelineCellEmpty(cell)
			}
		}

		if let cell = tableView.makeView(withIdentifier: TimelineViewController.timelineCellIdentifier, owner: nil) as? TimelineTableCellView {
			configure(cell)
			return cell
		}

		let cell = TimelineTableCellView()
		cell.identifier = TimelineViewController.timelineCellIdentifier
		configure(cell)
		return cell
	}

	func tableViewSelectionDidChange(_ notification: Notification) {
		if selectedArticles.isEmpty {
			selectionDidChange(nil)
			return
		}

		selectionDidChange(selectedArticles)
	}

	private func selectionDidChange(_ selectedArticles: ArticleArray?) {
		// Compare by identity, not content — re-pushing an updated article that the user is reading
		// would reset the article view scroll position.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/5387>
		let selectedArticleKeys = selectedArticles?.map { ArticleIdentityKey(accountID: $0.accountID, articleID: $0.articleID) }
		guard selectedArticleKeys != previouslySelectedArticleKeys else {
			return
		}
		previouslySelectedArticleKeys = selectedArticleKeys
		delegate?.timelineSelectionDidChange(self, selectedArticles: selectedArticles)
		delegate?.timelineInvalidatedRestorationState(self)
	}

	private func configureTimelineCell(_ cell: TimelineTableCellView, article: Article) {
		cell.objectValue = article
		let iconImage = article.iconImage()
		cell.cellData = TimelineCellData(article: article, showFeedName: showFeedNames, feedName: article.siteHost, byline: article.byline(), iconImage: iconImage, showIcon: showIcons)
	}

	private func iconFor(_ article: Article) -> IconImage? {
		if !showIcons {
			return nil
		}
		return IconImageCache.shared.imageForArticle(article)
	}

	private func avatarForAuthor(_ author: Author) -> IconImage? {
		return AuthorAvatarDownloader.shared.image(for: author)
	}

	private func makeTimelineCellEmpty(_ cell: TimelineTableCellView) {
		cell.objectValue = nil
		cell.cellData = TimelineCellData()
	}

	private func toggleArticleArchived(_ article: Article) {
		guard let undoManager = undoManager, let markReadCommand = MarkStatusCommand(initialArticles: [article], markingRead: !article.status.read, undoManager: undoManager) else {
			return
		}
		self.runCommand(markReadCommand)
	}

	/// Swiping from the leading edge archives an article, or moves an archived one back to the Queue.
	func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
		guard edge == .leading, let article = articles.articleAtRow(row) else {
			return []
		}
		let title = article.status.read ? NSLocalizedString("Move to Queue", comment: "Command") : NSLocalizedString("Archive", comment: "Command")
		let action = NSTableViewRowAction(style: .regular, title: title) { (_, _) in
			self.toggleArticleArchived(article)
			tableView.rowActionsVisible = false
		}
		action.image = article.status.read ? Assets.Images.swipeMarkUnread : Assets.Images.swipeMarkRead
		return [action]
	}
}

// MARK: - Private

private extension TimelineViewController {

	// The current article should stay in the timeline, and stay selected,
	// when the timeline updates and the sidebar selection hasn't changed —
	// even if the new fetch wouldn't otherwise include it.
	func fetchAndReplacePreservingSelectionAsync() {
		if let article = oneSelectedArticle, let account = article.account {
			exceptionArticleFetcher = SingleArticleFetcher(account: account, articleID: article.articleID)
		}
		let savedSelection = selectedArticleIDs()
		fetchAndReplaceArticlesAsync { [weak self] in
			self?.restoreSelection(savedSelection)
		}
	}

	func updateUnreadCount() {
		var count = 0
		for article in articles {
			if !article.status.read {
				count += 1
			}
		}
		unreadCount = count
	}

	func layoutDidChange() {
		performBlockAndRestoreSelection {
			configureTableView(for: layout)
			updateShowIcons()
			tableView.reloadData()
		}
		if tableView.selectedRow != -1 {
			tableView.scrollRowToVisible(tableView.selectedRow)
		}
	}

	func updateShowIcons() {
		if layout == .column {
			// The Feed column always shows the feed icon.
			self.showIcons = true
			return
		}

		if showFeedNames == .feed {
			self.showIcons = true
			return
		}

		if showFeedNames == .none {
			self.showIcons = false
			return
		}

		for article in articles {
			if let authors = article.authors {
				for author in authors {
					if author.avatarURL != nil {
						self.showIcons = true
						return
					}
				}
			}
		}

		self.showIcons = false
	}

	func emptyTheTimeline() {
		if !articles.isEmpty {
			articles = [Article]()
		}
	}

	func sortParametersDidChange() {
		performBlockAndRestoreSelection {
			let unsortedArticles = Set(articles)
			replaceArticles(with: unsortedArticles)
		}
	}

	func selectedArticleIDs() -> [String] {
		return selectedArticles.articleIDs()
	}

	func restoreSelection(_ articleIDs: [String]) {
		selectArticles(articleIDs)
		if tableView.selectedRow != -1 {
			tableView.scrollRowToVisible(tableView.selectedRow)
		}
	}

	func performBlockAndRestoreSelection(_ block: (() -> Void)) {
		let savedSelection = selectedArticleIDs()
		block()
		restoreSelection(savedSelection)
	}

	func rows(for articleID: String) -> [Int]? {
		updateArticleRowMapIfNeeded()
		return articleRowMap[articleID]
	}

	func rows(for article: Article) -> [Int]? {
		return rows(for: article.articleID)
	}

	func updateArticleRowMap() {
		var rowMap = [String: [Int]]()
		var index = 0
		for article in articles {
			if var indexes = rowMap[article.articleID] {
				indexes.append(index)
				rowMap[article.articleID] = indexes
			} else {
				rowMap[article.articleID] = [index]
			}
			index += 1
		}
		articleRowMap = rowMap
	}

	func updateArticleRowMapIfNeeded() {
		if articleRowMap.isEmpty {
			updateArticleRowMap()
		}
	}

	func indexesForArticleIDs(_ articleIDs: Set<String>) -> IndexSet {
		var indexes = IndexSet()

		for articleID in articleIDs {
			guard let rowsIndex = rows(for: articleID) else {
				continue
			}
			for rowIndex in rowsIndex {
				indexes.insert(rowIndex)
			}
		}

		return indexes
	}

	// MARK: - Appearance Change

	private func fontSizeDidChange() {
		cellAppearance = TimelineCellAppearance(showIcon: false, fontSize: fontSize)
		cellAppearanceWithIcon = TimelineCellAppearance(showIcon: true, fontSize: fontSize)
		updateRowHeights()
		performBlockAndRestoreSelection {
			tableView.reloadData()
		}
	}

	// MARK: - Fetching Articles

	func fetchAndReplaceArticlesSync() {
		// To be called when the user has made a change of selection in the sidebar.
		// It blocks the main thread, so that there’s no async delay,
		// so that the entire display refreshes at once.
		// It’s a better user experience this way.
		cancelPendingAsyncFetches()
		guard var representedObjects = representedObjects else {
			emptyTheTimeline()
			return
		}

		if exceptionArticleFetcher != nil {
			representedObjects.append(exceptionArticleFetcher as AnyObject)
			exceptionArticleFetcher = nil
		}

		let fetchedArticles = fetchUnsortedArticlesSync(for: representedObjects)
		replaceArticles(with: fetchedArticles)
	}

	func fetchAndReplaceArticlesAsync(completion: (() -> Void)? = nil) {
		// To be called when we need to do an entire fetch, but an async delay is okay.
		// Example: we have the Today feed selected, and the calendar day just changed.
		cancelPendingAsyncFetches()
		guard var representedObjects = representedObjects else {
			emptyTheTimeline()
			return
		}

		if exceptionArticleFetcher != nil {
			representedObjects.append(exceptionArticleFetcher as AnyObject)
			exceptionArticleFetcher = nil
		}

		fetchUnsortedArticlesAsync(for: representedObjects) { [weak self] (articles) in
			self?.replaceArticles(with: articles)
			completion?()
		}
	}

	func cancelPendingAsyncFetches() {
		fetchSerialNumber += 1
		fetchRequestQueue.cancelAllRequests()
	}

	func replaceArticles(with unsortedArticles: Set<Article>) {
		articles = Array(unsortedArticles).sorted(by: sortParameters)
	}

	func fetchUnsortedArticlesSync(for representedObjects: [Any]) -> Set<Article> {
		cancelPendingAsyncFetches()
		let fetchers = representedObjects.compactMap { $0 as? ArticleFetcher }
		if fetchers.isEmpty {
			return Set<Article>()
		}

		var fetchedArticles = Set<Article>()
		for fetchers in fetchers {
			if (fetchers as? SidebarItem)?.readFiltered(readFilterEnabledTable: Self.noReadFilters) ?? true {
				let articles = fetchers.fetchUnreadArticles()
				fetchedArticles.formUnion(articles)
			} else {
				let articles = fetchers.fetchArticles()
				fetchedArticles.formUnion(articles)
			}
		}
		return fetchedArticles
	}

	func fetchUnsortedArticlesAsync(for representedObjects: [Any], completion: @escaping ArticleSetBlock) {
		// The callback will *not* be called if the fetch is no longer relevant — that is,
		// if it’s been superseded by a newer fetch, or the timeline was emptied, etc., it won’t get called.
		precondition(Thread.isMainThread)
		cancelPendingAsyncFetches()
		let fetchers = representedObjects.compactMap { $0 as? ArticleFetcher }
		let fetchOperation = FetchRequestOperation(id: fetchSerialNumber, readFilterEnabledTable: Self.noReadFilters, fetchers: fetchers) { [weak self] (articles, operation) in
			precondition(Thread.isMainThread)
			guard !operation.isCanceled, let strongSelf = self, operation.id == strongSelf.fetchSerialNumber else {
				return
			}
			completion(articles)
		}
		fetchRequestQueue.add(fetchOperation)
	}

	func selectArticles(_ articleIDs: [String]) {
		let indexesToSelect = indexesForArticleIDs(Set(articleIDs))
		if indexesToSelect.isEmpty {
			tableView.deselectAll(self)
			return
		}
		tableView.selectRowIndexes(indexesToSelect, byExtendingSelection: false)
	}

	func queueFetchAndMergeArticles() {
		TimelineViewController.fetchAndMergeArticlesQueue.add(self, #selector(fetchAndMergeArticles))
	}

	func representedObjectArraysAreEqual(_ objects1: [AnyObject]?, _ objects2: [AnyObject]?) -> Bool {
		if objects1 == nil && objects2 == nil {
			return true
		}
		guard let objects1 = objects1, let objects2 = objects2 else {
			return false
		}
		if objects1.count != objects2.count {
			return false
		}

		var ix = 0
		for oneObject in objects1 {
			if oneObject !== objects2[ix] {
				return false
			}
			ix += 1
		}
		return true
	}

	func representedObjectsContainsAnyPseudoFeed() -> Bool {
		return representedObjects?.contains(where: { $0 is PseudoFeed}) ?? false
	}

	func representedObjectsContainAnyFolder() -> Bool {
		return representedObjects?.contains(where: { $0 is Folder }) ?? false
	}

	func representedObjectsContainsAnyFeed(_ feeds: Set<Feed>) -> Bool {
		// Return true if there’s a match or if a folder contains (recursively) one of feeds

		guard let representedObjects = representedObjects else {
			return false
		}
		for representedObject in representedObjects {
			if let feed = representedObject as? Feed {
				for oneFeed in feeds {
					if feed.feedID == oneFeed.feedID || feed.url == oneFeed.url {
						return true
					}
				}
			} else if let folder = representedObject as? Folder {
				for oneFeed in feeds {
					if folder.hasFeed(with: oneFeed.feedID) || folder.hasFeed(withURL: oneFeed.url) {
						return true
					}
				}
			}
		}
		return false
	}
}
