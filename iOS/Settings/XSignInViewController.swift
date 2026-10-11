//
//  XSignInViewController.swift
//  NetNewsList
//
//  Shows X's own sign-in page in the X website data store, so the extractor can load
//  posts that X shows only to signed-in people. Dismisses itself once X has signed in.
//

import UIKit
import WebKit
import RSWeb

final class XSignInViewController: UIViewController {

	private lazy var webView: WKWebView = {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = XAccount.shared.websiteDataStore
		let webView = WKWebView(frame: .zero, configuration: configuration)
		// The extractor's user agent, so X sees the same browser that later loads the posts.
		webView.customUserAgent = UserAgent.browserUserAgent
		return webView
	}()

	override func loadView() {
		view = webView
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = NSLocalizedString("Sign In to X", comment: "Screen title")
		navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
			self?.dismiss(animated: true)
		})
		NotificationCenter.default.addObserver(self, selector: #selector(xAccountSignInStateDidChange(_:)), name: .XAccountSignInStateDidChange, object: nil)
		if let url = URL(string: XAccount.signInAddress) {
			webView.load(URLRequest(url: url))
		}
	}

	@objc func xAccountSignInStateDidChange(_ note: Notification) {
		if XAccount.shared.isSignedIn {
			dismiss(animated: true)
		}
	}
}
