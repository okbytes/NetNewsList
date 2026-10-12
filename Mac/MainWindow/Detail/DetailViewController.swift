//
//  DetailViewController.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import WebKit
import RSCore
import Articles
import RSWeb

enum DetailState: Equatable {
	case noSelection
	case multipleSelection
	case loading
	case article(Article, CGFloat?)
}

final class DetailViewController: NSViewController, WKUIDelegate {

	@IBOutlet var containerView: DetailContainerView!
	@IBOutlet var statusBarView: DetailStatusBarView!

	private lazy var webViewController = createWebViewController()

	var windowState: DetailWindowState {
		webViewController.windowState
	}

	convenience init() {
		self.init(nibName: "DetailView", bundle: nil)
	}

	override func viewDidLoad() {
		containerView.contentView = webViewController.view
	}

	// MARK: - API

	func setState(_ state: DetailState) {
		webViewController.state = state
	}

	func stopMediaPlayback() {
		webViewController.stopMediaPlayback()
	}

	func canScrollDown() async -> Bool {
		await webViewController.canScrollDown()
	}

	func canScrollUp() async -> Bool {
		await webViewController.canScrollUp()
	}

	override func scrollPageDown(_ sender: Any?) {
		webViewController.scrollPageDown(sender)
	}

	override func scrollPageUp(_ sender: Any?) {
		webViewController.scrollPageUp(sender)
	}

	// MARK: - Navigation

	func focus() {
		guard let window = webViewController.webView.window else {
			return
		}
		window.makeFirstResponderUnlessDescendantIsFirstResponder(webViewController.webView)
	}
}

// MARK: - DetailWebViewControllerDelegate

extension DetailViewController: DetailWebViewControllerDelegate {

	func mouseDidEnter(_: DetailWebViewController, link: String) {
		guard !link.isEmpty else {
			return
		}
		statusBarView.mouseoverLink = link
	}

	func mouseDidExit(_: DetailWebViewController) {
		statusBarView.mouseoverLink = nil
	}
}

// MARK: - Private

private extension DetailViewController {

	func createWebViewController() -> DetailWebViewController {
		let controller = DetailWebViewController()
		controller.delegate = self
		controller.state = .noSelection
		return controller
	}
}
