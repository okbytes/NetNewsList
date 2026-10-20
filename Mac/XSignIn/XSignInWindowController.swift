//
//  XSignInWindowController.swift
//  NetNewsList
//
//  Shows X's own sign-in page in the X website data store, so the extractor can load
//  posts that X shows only to signed-in people. Closes itself once X has signed in.
//
//  Sign in with Google (and Apple) opens a popup window from X's page; a web view makes
//  none unless asked, so the popup gets a window of its own here, in the same data store,
//  and closes when the sign-in page closes it.
//

import AppKit
import WebKit
import RSWeb

final class XSignInWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate {

	private var webView: WKWebView?
	private var signInCheck: Task<Void, Never>?
	private var popupWindows = [NSWindow]()

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
		webView.uiDelegate = self
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
		guard notification.object as? NSWindow == window else {
			return
		}
		webView?.stopLoading()
		signInCheck?.cancel()
		signInCheck = nil
		closePopups()
	}

	// MARK: - WKUIDelegate

	/// The popup X's page opens for Sign in with Google or Apple. It has to be a real new web view
	/// made from `configuration`, so the pages can talk to each other (`window.opener`).
	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		let width = windowFeatures.width.map { CGFloat(truncating: $0) } ?? 480
		let height = windowFeatures.height.map { CGFloat(truncating: $0) } ?? 640
		let popupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(width, 360), height: max(height, 480)), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
		popupWindow.title = NSLocalizedString("Sign In", comment: "Window title")
		popupWindow.isReleasedWhenClosed = false
		let popupWebView = WKWebView(frame: popupWindow.contentLayoutRect, configuration: configuration)
		popupWebView.customUserAgent = UserAgent.browserUserAgent
		popupWebView.autoresizingMask = [.width, .height]
		popupWebView.uiDelegate = self
		popupWindow.contentView = popupWebView
		popupWindow.delegate = self
		popupWindows.append(popupWindow)
		if let window {
			popupWindow.setFrameOrigin(NSPoint(x: window.frame.midX - popupWindow.frame.width / 2, y: window.frame.midY - popupWindow.frame.height / 2))
		} else {
			popupWindow.center()
		}
		popupWindow.makeKeyAndOrderFront(nil)
		return popupWebView
	}

	/// The page closed its popup (the sign-in finished).
	func webViewDidClose(_ webView: WKWebView) {
		guard let popupWindow = popupWindows.first(where: { $0.contentView == webView }) else {
			return
		}
		popupWindows.removeAll { $0 == popupWindow }
		popupWindow.close()
		Task { @MainActor in
			await XAccount.shared.updateSignInState()
		}
	}

	private func closePopups() {
		for popupWindow in popupWindows {
			(popupWindow.contentView as? WKWebView)?.stopLoading()
			popupWindow.close()
		}
		popupWindows.removeAll()
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
