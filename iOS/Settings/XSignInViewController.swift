//
//  XSignInViewController.swift
//  NetNewsList
//
//  Shows X's own sign-in page in the X website data store, so the extractor can load
//  posts that X shows only to signed-in people. Dismisses itself once X has signed in.
//
//  Sign in with Google (and Apple) opens a popup from X's page; a web view makes none unless
//  asked, so the popup gets a screen of its own here, in the same data store, and goes away
//  when the sign-in page closes it.
//

import UIKit
import WebKit
import RSWeb

final class XSignInViewController: UIViewController, WKUIDelegate {

	private var signInCheck: Task<Void, Never>?
	private var popupViewControllers = [XSignInPopupViewController]()

	private lazy var webView: WKWebView = {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = XAccount.shared.websiteDataStore
		let webView = WKWebView(frame: .zero, configuration: configuration)
		// The extractor's user agent, so X sees the same browser that later loads the posts.
		webView.customUserAgent = UserAgent.browserUserAgent
		webView.uiDelegate = self
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

	// MARK: - WKUIDelegate

	/// The popup X's page opens for Sign in with Google or Apple. It has to be a real new web view
	/// made from `configuration`, so the pages can talk to each other (`window.opener`).
	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		let popup = XSignInPopupViewController(configuration: configuration)
		popup.webView.uiDelegate = self
		popupViewControllers.append(popup)
		let navigationController = UINavigationController(rootViewController: popup)
		(presentedViewController ?? self).present(navigationController, animated: true)
		return popup.webView
	}

	/// The page closed its popup (the sign-in finished).
	func webViewDidClose(_ webView: WKWebView) {
		guard let popup = popupViewControllers.first(where: { $0.webView == webView }) else {
			return
		}
		popupViewControllers.removeAll { $0 == popup }
		popup.dismiss(animated: true)
		Task { @MainActor in
			await XAccount.shared.updateSignInState()
		}
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

/// A popup the X sign-in page opened, shown as its own screen.
private final class XSignInPopupViewController: UIViewController {

	let webView: WKWebView

	init(configuration: WKWebViewConfiguration) {
		webView = WKWebView(frame: .zero, configuration: configuration)
		webView.customUserAgent = UserAgent.browserUserAgent
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	override func loadView() {
		view = webView
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = NSLocalizedString("Sign In", comment: "Screen title")
		navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
			self?.webView.stopLoading()
			self?.dismiss(animated: true)
		})
	}
}
