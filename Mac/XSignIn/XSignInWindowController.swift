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
	private var signInCheck: Task<Void, Never>?

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
	}

	override func showWindow(_ sender: Any?) {
		if let webView, webView.url == nil, let url = URL(string: XAccount.signInAddress) {
			webView.load(URLRequest(url: url))
			window?.center()
		}
		super.showWindow(sender)
		startCheckingSignIn()
	}

	func windowWillClose(_ notification: Notification) {
		webView?.stopLoading()
		signInCheck?.cancel()
		signInCheck = nil
	}

	/// X's sign-in happens inside its page, and the cookie store doesn't always report the
	/// new session cookie, so check every couple of seconds while the window is open.
	private func startCheckingSignIn() {
		guard signInCheck == nil else {
			return
		}
		signInCheck = Task { @MainActor [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(2))
				await XAccount.shared.updateSignInState()
				if XAccount.shared.isSignedIn {
					self?.close()
					return
				}
			}
		}
	}
}
