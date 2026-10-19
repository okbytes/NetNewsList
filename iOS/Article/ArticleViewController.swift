//
//  ArticleViewController.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 4/8/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import os
import WebKit
import RSCore
import Account
import Articles

final class ArticleViewController: UIViewController {

	@IBOutlet private var searchBar: ArticleSearchBar!
	@IBOutlet private var searchBarBottomConstraint: NSLayoutConstraint!

	/// Holds the article's web view. It has no data source, so there's no swiping between articles:
	/// a horizontal swipe is only ever the back swipe to the list. The keyboard still moves between them.
	private var pageViewController: UIPageViewController!

	private var currentWebViewController: WebViewController? {
		return pageViewController?.viewControllers?.first as? WebViewController
	}

	// The article's actions are all in the navigation bar: Archive or Move to Queue, Open in Browser and Share.
	private lazy var archiveBarButtonItem = Self.barButtonItem(title: NSLocalizedString("Archive", comment: "Command"), image: Assets.Images.archive, target: self, action: #selector(toggleRead(_:)))
	private lazy var openInBrowserBarButtonItem = Self.barButtonItem(title: NSLocalizedString("Open in Browser", comment: "Command"), image: Assets.Images.safari, target: self, action: #selector(openInBrowser(_:)))
	private lazy var shareBarButtonItem = Self.barButtonItem(title: NSLocalizedString("Share", comment: "Share button"), image: Assets.Images.share, target: self, action: #selector(showActivityDialog(_:)))

	weak var coordinator: SceneCoordinator!

	private let poppableDelegate = PoppableGestureRecognizerDelegate()
	private weak var originalPopGestureRecognizerDelegate: UIGestureRecognizerDelegate?
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleViewController")

	var article: Article? {
		didSet {
			Self.logger.debug("ArticleViewController: article didSet: \(self.article?.accountID ?? "nil") \(self.article?.articleID ?? "nil") \(self.article?.title ?? "nil")")

			if oldValue != article {
				// The launch-restoration scroll position belongs only to the restored article.
				// <https://github.com/Ranchero-Software/NetNewsWire/issues/5243>
				restoreScrollPosition = nil
			}

			if let controller = currentWebViewController, controller.article != article {
				controller.setArticle(article)
				DispatchQueue.main.async {
					// You have to set the view controller to clear out the UIPageViewController child controller cache.
					// You also have to do it in an async call or you will get a strange assertion error.
					self.pageViewController.setViewControllers([controller], direction: .forward, animated: false, completion: nil)
				}
			}
			updateUI()
		}
	}

	/// The launch-restoration scroll offset for the restored article.
	var restoreScrollPosition: Int? {
		didSet {
			if let restoreScrollPosition {
				currentWebViewController?.setScrollPosition(articleWindowScrollY: restoreScrollPosition)
			}
		}
	}

	private let keyboardManager = KeyboardManager(type: .detail)
	override var keyCommands: [UIKeyCommand]? {
		return keyboardManager.keyCommands
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(statusesDidChange(_:)), name: .StatusesDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryDidChange(_:)), name: UIContentSizeCategory.didChangeNotification, object: nil)

		let appearance = UINavigationBarAppearance()
		appearance.configureWithDefaultBackground()
		navigationItem.standardAppearance = appearance
		navigationItem.scrollEdgeAppearance = appearance
		navigationItem.compactAppearance = appearance

		// Right to left: Share at the trailing edge, Archive leftmost.
		navigationItem.rightBarButtonItems = [shareBarButtonItem, openInBrowserBarButtonItem, archiveBarButtonItem]

		pageViewController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: [:])

		pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(pageViewController.view)
		addChild(pageViewController!)
		NSLayoutConstraint.activate([
			view.leadingAnchor.constraint(equalTo: pageViewController.view.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: pageViewController.view.trailingAnchor),
			view.topAnchor.constraint(equalTo: pageViewController.view.topAnchor),
			view.bottomAnchor.constraint(equalTo: pageViewController.view.bottomAnchor)
		])

		let controller = createWebViewController(article, updateView: true)
		if let restoreScrollPosition {
			controller.setScrollPosition(articleWindowScrollY: restoreScrollPosition)
		}

		self.pageViewController.setViewControllers([controller], direction: .forward, animated: false, completion: nil)

		// Search bar
		searchBar.translatesAutoresizingMaskIntoConstraints = false
		NotificationCenter.default.addObserver(self, selector: #selector(beginFind(_:)), name: .FindInArticle, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(endFind(_:)), name: .EndFindInArticle, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIWindow.keyboardWillChangeFrameNotification, object: nil)
		searchBar.delegate = self
		view.bringSubviewToFront(searchBar)

		updateUI()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if #available(iOS 26, *) {
			navigationController?.navigationBar.topItem?.subtitle = nil
		}
		coordinator.isArticleViewControllerPending = false
		searchBar.shouldBeginEditing = true
		// Scoped to the article screen — restored in viewDidDisappear.
		if let parentNavController = navigationController?.parent as? UINavigationController,
			let gestureRecognizer = parentNavController.interactivePopGestureRecognizer {
			if gestureRecognizer.delegate !== poppableDelegate {
				originalPopGestureRecognizerDelegate = gestureRecognizer.delegate
			}
			poppableDelegate.navigationController = parentNavController
			gestureRecognizer.delegate = poppableDelegate
		}
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		if searchBar != nil && !searchBar.isHidden {
			endFind()
			searchBar.shouldBeginEditing = false
		}
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		restoreOriginalPopGestureRecognizerDelegate()
	}

	func updateUI() {

		guard let article = article else {
			archiveBarButtonItem.isEnabled = false
			openInBrowserBarButtonItem.isEnabled = false
			shareBarButtonItem.isEnabled = false
			return
		}

		let permalinkPresent = article.preferredLink != nil
		openInBrowserBarButtonItem.isEnabled = permalinkPresent
		shareBarButtonItem.isEnabled = permalinkPresent

		let title: String
		if article.status.read {
			title = NSLocalizedString("Move to Queue", comment: "Command")
			archiveBarButtonItem.image = Assets.Images.moveToQueue
			archiveBarButtonItem.isEnabled = article.isAvailableToMarkUnread
		} else {
			title = NSLocalizedString("Archive", comment: "Command")
			archiveBarButtonItem.image = Assets.Images.archive
			archiveBarButtonItem.isEnabled = true
		}
		archiveBarButtonItem.title = title
		archiveBarButtonItem.accessibilityLabel = title
	}

	// MARK: Notifications

	@objc dynamic func unreadCountDidChange(_ notification: Notification) {
		updateUI()
	}

	@objc func statusesDidChange(_ note: Notification) {
		guard let articleIDs = note.userInfo?[Account.UserInfoKey.articleIDs] as? Set<String> else {
			return
		}
		guard let article = article else {
			return
		}
		if articleIDs.contains(article.articleID) {
			updateUI()
		}
	}

	@objc func contentSizeCategoryDidChange(_ note: Notification) {
		currentWebViewController?.fullReload()
	}

	// MARK: Actions

	@objc func openInBrowser(_ sender: Any?) {
		coordinator.showBrowserForCurrentArticle()
	}

	@objc func toggleRead(_ sender: Any?) {
		coordinator.toggleReadForCurrentArticle()
	}

	@objc func showActivityDialog(_ sender: Any?) {
		currentWebViewController?.showActivityDialog(popOverBarButtonItem: shareBarButtonItem)
	}

	// MARK: Keyboard Shortcuts

	@objc func navigateToTimeline(_ sender: Any?) {
		coordinator.navigateToTimeline()
	}

	// MARK: API

	func focus() {
		currentWebViewController?.focus()
	}

	func canScrollDown() -> Bool {
		return currentWebViewController?.canScrollDown() ?? false
	}

	func canScrollUp() -> Bool {
		return currentWebViewController?.canScrollUp() ?? false
	}

	func scrollPageDown() {
		currentWebViewController?.scrollPageDown()
	}

	func scrollPageUp() {
		currentWebViewController?.scrollPageUp()
	}

	func setScrollPosition(articleWindowScrollY: Int) {
		currentWebViewController?.setScrollPosition(articleWindowScrollY: articleWindowScrollY)
	}
}

// MARK: Find in Article
public extension Notification.Name {
	static let FindInArticle = Notification.Name("FindInArticle")
	static let EndFindInArticle = Notification.Name("EndFindInArticle")
}

extension ArticleViewController: SearchBarDelegate {

	func searchBar(_ searchBar: ArticleSearchBar, textDidChange searchText: String) {
		currentWebViewController?.searchText(searchText) { found in
			searchBar.resultsCount = found.count

			if let index = found.index {
				searchBar.selectedResult = index + 1
			}
		}
	}

	func doneWasPressed(_ searchBar: ArticleSearchBar) {
		NotificationCenter.default.post(name: .EndFindInArticle, object: nil)
	}

	func nextWasPressed(_ searchBar: ArticleSearchBar) {
		if searchBar.selectedResult < searchBar.resultsCount {
			currentWebViewController?.selectNextSearchResult()
			searchBar.selectedResult += 1
		}
	}

	func previousWasPressed(_ searchBar: ArticleSearchBar) {
		if searchBar.selectedResult > 1 {
			currentWebViewController?.selectPreviousSearchResult()
			searchBar.selectedResult -= 1
		}
	}
}

extension ArticleViewController {

	@objc func beginFind(_ _: Any? = nil) {
		searchBar.isHidden = false
		currentWebViewController?.additionalSafeAreaInsets.bottom = searchBar.frame.height
		searchBar.becomeFirstResponder()
	}

	@objc func endFind(_ _: Any? = nil) {
		searchBar.resignFirstResponder()
		searchBar.isHidden = true
		currentWebViewController?.additionalSafeAreaInsets.bottom = 0
		currentWebViewController?.endSearch()
	}

	@objc func keyboardWillChangeFrame(_ notification: Notification) {
		if !searchBar.isHidden,
			let duration = notification.userInfo?[UIWindow.keyboardAnimationDurationUserInfoKey] as? Double,
			let curveRaw = notification.userInfo?[UIWindow.keyboardAnimationCurveUserInfoKey] as? UInt,
			let frame = notification.userInfo?[UIWindow.keyboardFrameEndUserInfoKey] as? CGRect {

			let curve = UIView.AnimationOptions(rawValue: curveRaw)
			let newHeight = view.safeAreaLayoutGuide.layoutFrame.maxY - frame.minY
			currentWebViewController?.additionalSafeAreaInsets.bottom = newHeight + searchBar.frame.height + 10
			self.searchBarBottomConstraint.constant = newHeight
			UIView.animate(withDuration: duration, delay: 0, options: curve, animations: {
				self.view.layoutIfNeeded()
			})
		}
	}

}

// MARK: Private

private extension ArticleViewController {

	static func barButtonItem(title: String, image: UIImage, target: ArticleViewController, action: Selector) -> UIBarButtonItem {
		let item = UIBarButtonItem(image: image, style: .plain, target: target, action: action)
		item.title = title
		item.accessibilityLabel = title
		return item
	}

	func createWebViewController(_ article: Article?, updateView: Bool = true) -> WebViewController {
		let controller = WebViewController()
		controller.coordinator = coordinator
		controller.setArticle(article, updateView: updateView)
		return controller
	}

	func restoreOriginalPopGestureRecognizerDelegate() {
		guard let gestureRecognizer = poppableDelegate.navigationController?.interactivePopGestureRecognizer,
			gestureRecognizer.delegate === poppableDelegate else {
			return
		}
		gestureRecognizer.delegate = originalPopGestureRecognizerDelegate
	}

}
