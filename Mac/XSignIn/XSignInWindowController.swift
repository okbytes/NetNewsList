//
//  XSignInWindowController.swift
//  NetNewsList
//
//  Shows X's own sign-in page in the X website data store, so the extractor can load
//  posts that X shows only to signed-in people. Closes itself once X has signed in.
//

import AppKit
import WebKit
import RSWeb

final class XSignInWindowController: NSWindowController, NSWindowDelegate {

	private var webView: WKWebView?

	convenience init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
		window.title = NSLocalizedString("Sign In to X", comment: "Window title")
		window.isReleasedWhenClosed = false
		self.init(window: window)

		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = XAccount.shared.websiteDataStore
		let webView = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
		// The extractor's user agent, so X sees the same browser that later loads the posts.
		webView.customUserAgent = UserAgent.browserUserAgent
		webView.autoresizingMask = [.width, .height]
		window.contentView = webView
		window.delegate = self
		self.webView = webView

		NotificationCenter.default.addObserver(self, selector: #selector(xAccountSignInStateDidChange(_:)), name: .XAccountSignInStateDidChange, object: nil)
	}

	override func showWindow(_ sender: Any?) {
		if let webView, webView.url == nil, let url = URL(string: XAccount.signInAddress) {
			webView.load(URLRequest(url: url))
			window?.center()
		}
		super.showWindow(sender)
	}

	func windowWillClose(_ notification: Notification) {
		webView?.stopLoading()
	}

	@objc func xAccountSignInStateDidChange(_ note: Notification) {
		if XAccount.shared.isSignedIn {
			close()
		}
	}
}
