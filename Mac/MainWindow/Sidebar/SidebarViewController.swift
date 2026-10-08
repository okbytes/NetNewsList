//
//  SidebarViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import RSTree
import Articles
import Account
import RSCore
import Images

extension Notification.Name {
	static let appleSideBarDefaultIconSizeChanged = Notification.Name("AppleSideBarDefaultIconSizeChanged")
}

@MainActor protocol SidebarDelegate: AnyObject {
	func sidebarSelectionDidChange(_: SidebarViewController, selectedObjects: [AnyObject]?)
	func unreadCount(for: AnyObject) -> Int
	func sidebarInvalidatedRestorationState(_: SidebarViewController)
}

/// The sidebar: the fixed lists Inbox, Starred, Archive and All. A web address
/// dropped on it is saved.
@objc final class SidebarViewController: NSViewController, NSOutlineViewDelegate, NSMenuDelegate, UndoableCommandRunner {

	@IBOutlet var outlineView: SidebarOutlineView!

	weak var delegate: SidebarDelegate?

	weak var splitViewItem: NSSplitViewItem?

	var windowState: SidebarWindowState {
		let selectedFeeds = selectedSidebarItems.compactMap { $0.sidebarItemID?.userInfo as? [String: String] }
		return SidebarWindowState(isReadFiltered: false, expandedContainers: [], selectedFeeds: selectedFeeds)
	}

	let treeControllerDelegate = SidebarTreeControllerDelegate()
	lazy var treeController: TreeController = {
		TreeController(delegate: treeControllerDelegate)
	}()
	lazy var dataSource: SidebarOutlineDataSource = {
		SidebarOutlineDataSource(treeController: treeController)
	}()

	var undoableCommands = [UndoableCommand]()

	var selectedObjects: [AnyObject] {
		selectedNodes.representedObjects()
	}

	private let keyboardDelegate = SidebarKeyboardDelegate()

	// MARK: - NSViewController

	convenience init() {
		self.init(nibName: "SidebarView", bundle: nil)
	}

	override func viewDidLoad() {
		keyboardDelegate.sidebarViewController = self
		outlineView.keyboardDelegate = keyboardDelegate
		outlineView.dataSource = dataSource
		outlineView.registerForDraggedTypes(DroppedWebPages.pasteboardTypes)

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleUnreadCountDisplaySettingDidChange(_:)), name: .unreadCountDisplaySettingDidChange, object: nil)
		DistributedNotificationCenter.default().addObserver(self, selector: #selector(appleSideBarDefaultIconSizeChanged(_:)), name: .appleSideBarDefaultIconSizeChanged, object: nil)

		outlineView.reloadData()
		for topLevelNode in treeController.rootNode.childNodes {
			outlineView.expandItem(topLevelNode)
		}
	}

	// MARK: State Restoration

	func restoreState(from state: SidebarWindowState?) {
		guard let state else {
			return
		}
		selectSidebarItems(withIdentifiers: Set(state.selectedFeeds.compactMap { SidebarItemIdentifier(userInfo: $0) }))
	}

	/// Restore state using legacy state restoration data.
	///
	/// TODO: Delete for NetNewsWire 7.
	func restoreLegacyState(from state: [AnyHashable: Any]) {
		guard let selectedFeedsState = state[UserInfoKey.selectedFeedsState] as? [[String: String]] else {
			return
		}
		selectSidebarItems(withIdentifiers: Set(selectedFeedsState.compactMap { SidebarItemIdentifier(userInfo: $0) }))
	}

	// MARK: - Notifications

	@objc func unreadCountDidChange(_ note: Notification) {
		guard let representedObject = note.object else {
			return
		}
		if let timelineViewController = representedObject as? TimelineViewController {
			configureUnreadCountForCellsForRepresentedObjects(timelineViewController.representedObjects)
		} else {
			configureUnreadCountForCellsForRepresentedObjects([representedObject as AnyObject])
		}
	}

	@objc func handleUnreadCountDisplaySettingDidChange(_ notification: Notification) {
		outlineView.enumerateAvailableRowViews { rowView, _ in
			(rowView.view(atColumn: 0) as? SidebarCell)?.updateUnreadCountView()
		}
	}

	@objc func appleSideBarDefaultIconSizeChanged(_ note: Notification) {
		// The outline view doesn't have the new row style size set yet when we get
		// this notification, so give it half a second to catch up.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			let savedSelection = self.selectedNodes
			self.outlineView.reloadData()
			self.restoreSelection(to: savedSelection, sendNotificationIfChanged: true)
		}
	}

	// MARK: - Actions

	@IBAction func gotoInbox(_ sender: Any?) {
		selectFeed(SmartFeedsController.shared.unreadFeed)
		focus()
	}

	@IBAction func gotoStarred(_ sender: Any?) {
		selectFeed(SmartFeedsController.shared.starredFeed)
		focus()
	}

	@IBAction func gotoArchive(_ sender: Any?) {
		selectFeed(SmartFeedsController.shared.archiveFeed)
		focus()
	}

	@IBAction func gotoAllArticles(_ sender: Any?) {
		selectFeed(SmartFeedsController.shared.allArticlesFeed)
		focus()
	}

	// MARK: - Navigation

	func canGoToNextUnread(wrappingToTop wrapping: Bool = false) -> Bool {
		nextSelectableRowWithUnreadArticle(wrappingToTop: wrapping) != nil
	}

	func goToNextUnread(wrappingToTop wrapping: Bool = false) {
		guard let row = nextSelectableRowWithUnreadArticle(wrappingToTop: wrapping) else {
			assertionFailure("goToNextUnread called before checking if there is a next unread.")
			return
		}
		NSCursor.setHiddenUntilMouseMoves(true)
		outlineView.selectRowIndexes(IndexSet([row]), byExtendingSelection: false)
		outlineView.scrollTo(row: row)
	}

	func focus() {
		if splitViewItem?.isCollapsed == true {
			return
		}
		outlineView.window?.makeFirstResponderUnlessDescendantIsFirstResponder(outlineView)
	}

	// MARK: - Contextual Menu

	func contextualMenuForClickedRows() -> NSMenu? {
		let row = outlineView.clickedRow
		guard row != -1, let node = nodeForRow(row) else {
			return menu(for: nil)
		}
		if outlineView.selectedRowIndexes.contains(row) {
			return menu(for: selectedObjects)
		}
		return menu(for: [node.representedObject])
	}

	// MARK: - NSMenuDelegate

	public func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		guard let contextualMenu = contextualMenuForClickedRows() else {
			return
		}
		menu.takeItems(from: contextualMenu)
	}

	// MARK: - NSOutlineViewDelegate

	func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
		guard let node = item as? Node else {
			return nil
		}
		if node.isGroupItem {
			let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "HeaderCell"), owner: self) as? NSTableCellView
			cell?.textField?.stringValue = nameFor(node)
			return cell
		}
		let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "DataCell"), owner: self) as? SidebarCell
		if let cell {
			configure(cell, node)
		}
		return cell
	}

	func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
		(item as? Node)?.isGroupItem ?? false
	}

	func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
		// Don’t allow selecting group items: keep the current selection instead.
		for index in proposedSelectionIndexes {
			if let node = nodeForRow(index), node.isGroupItem {
				return outlineView.selectedRowIndexes
			}
		}
		return proposedSelectionIndexes
	}

	func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
		!self.outlineView(outlineView, isGroupItem: item)
	}

	func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
		false
	}

	func outlineViewSelectionDidChange(_ notification: Notification) {
		selectionDidChange(selectedObjects.isEmpty ? nil : selectedObjects)
	}

	// MARK: - API

	func selectFeed(_ sidebarItem: SidebarItem) {
		outlineView.revealAndSelectRepresentedObject(sidebarItem as AnyObject, treeController)
	}

	/// Handoff and notifications name an article; every article is in All.
	func deepLinkRevealAndSelect(for userInfo: [AnyHashable: Any]) {
		selectFeed(SmartFeedsController.shared.allArticlesFeed)
	}
}

// MARK: - Private

private extension SidebarViewController {

	var selectedNodes: [Node] {
		outlineView.selectedItems as? [Node] ?? [Node]()
	}

	var selectedSidebarItems: [SidebarItem] {
		selectedNodes.compactMap { $0.representedObject as? SidebarItem }
	}

	func selectSidebarItems(withIdentifiers identifiers: Set<SidebarItemIdentifier>) {
		var selectIndexes = IndexSet()
		treeController.visitNodes { node in
			if let sidebarItemID = (node.representedObject as? SidebarItemIdentifiable)?.sidebarItemID, identifiers.contains(sidebarItemID) {
				let row = outlineView.row(forItem: node)
				if row >= 0 {
					selectIndexes.insert(row)
				}
			}
		}
		outlineView.selectRowIndexes(selectIndexes, byExtendingSelection: false)
		focus()
	}

	func restoreSelection(to nodes: [Node], sendNotificationIfChanged: Bool) {
		if selectedNodes == nodes {
			return
		}
		var indexes = IndexSet()
		for node in nodes {
			let row = outlineView.row(forItem: node as Any)
			if row > -1 {
				indexes.insert(row)
			}
		}
		outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
		if selectedNodes != nodes && sendNotificationIfChanged {
			selectionDidChange(selectedObjects)
		}
	}

	func selectionDidChange(_ selectedObjects: [AnyObject]?) {
		delegate?.sidebarSelectionDidChange(self, selectedObjects: selectedObjects)
		delegate?.sidebarInvalidatedRestorationState(self)
	}

	func nodeForRow(_ row: Int) -> Node? {
		guard row >= 0, row < outlineView.numberOfRows else {
			return nil
		}
		return outlineView.item(atRow: row) as? Node
	}

	func rowHasAtLeastOneUnreadArticle(_ row: Int) -> Bool {
		guard let unreadCountProvider = nodeForRow(row)?.representedObject as? UnreadCountProvider else {
			return false
		}
		return unreadCountProvider.unreadCount > 0
	}

	func rowIsGroupItem(_ row: Int) -> Bool {
		guard let node = nodeForRow(row) else {
			return false
		}
		return outlineView.isGroupItem(node)
	}

	func nextSelectableRowWithUnreadArticle(wrappingToTop wrapping: Bool = false) -> Int? {
		let numberOfRows = outlineView.numberOfRows
		let startRow = outlineView.selectedRow + 1

		let orderedRows: [Int]
		if startRow == numberOfRows {
			// The last row is selected, so start at the beginning if wrapping is allowed.
			orderedRows = wrapping ? Array(0..<numberOfRows) : []
		} else {
			orderedRows = Array(startRow..<numberOfRows) + (wrapping ? Array(0..<startRow) : [])
		}
		return orderedRows.first { rowHasAtLeastOneUnreadArticle($0) && !rowIsGroupItem($0) }
	}

	func configure(_ cell: SidebarCell, _ node: Node) {
		cell.cellAppearance = SidebarCellAppearance(rowSizeStyle: outlineView.effectiveRowSizeStyle)
		cell.name = nameFor(node)
		configureUnreadCount(cell, node)
		cell.updateUnreadCountView() // A reused cell may predate a display setting change
		cell.iconImage = (node.representedObject as? SmallIconProvider)?.smallIcon
		cell.shouldShowImage = node.representedObject is SmallIconProvider
	}

	func configureUnreadCount(_ cell: SidebarCell, _ node: Node) {
		cell.unreadCount = unreadCountFor(node)
	}

	func nameFor(_ node: Node) -> String {
		(node.representedObject as? DisplayNameProvider)?.nameForDisplay ?? ""
	}

	func unreadCountFor(_ node: Node) -> Int {
		// The one and only selected list takes its count from the timeline, which
		// accounts for articles the timeline is still showing.
		if selectedNodes.count == 1, selectedNodes.first === node {
			return delegate?.unreadCount(for: node.representedObject) ?? 0
		}
		return (node.representedObject as? UnreadCountProvider)?.unreadCount ?? 0
	}

	func configureUnreadCountForCellsForRepresentedObjects(_ representedObjects: [AnyObject]?) {
		guard let representedObjects else {
			return
		}
		outlineView.enumerateAvailableRowViews { rowView, row in
			guard let cell = rowView.view(atColumn: 0) as? SidebarCell, let node = nodeForRow(row) else {
				return
			}
			if representedObjects.contains(where: { $0 === node.representedObject }) {
				configureUnreadCount(cell, node)
			}
		}
	}
}
