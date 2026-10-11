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

	private var signInCheck: Task<Void, Never>?

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
		if let url = URL(string: XAccount.signInAddress) {
			webView.load(URLRequest(url: url))
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		startCheckingSignIn()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		signInCheck?.cancel()
		signInCheck = nil
	}

	/// X's sign-in happens inside its page, and the cookie store doesn't always report the
	/// new session cookie, so check every couple of seconds while the screen is open.
	private func startCheckingSignIn() {
		guard signInCheck == nil else {
			return
		}
		signInCheck = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(2))
				await XAccount.shared.updateSignInState()
				if XAccount.shared.isSignedIn {
					self?.dismiss(animated: true)
					return
				}
			}
		}
	}
}
