//
//  ICloudSignInWindowController.swift
//  NetNewsList
//
//  Apple’s iCloud sign-in page, for a copy of the app that reaches iCloud over the web
//  (`CloudKitWebSync`): on a Mac whose macOS isn’t signed in to the user’s iCloud, the app
//  signs in by itself. The page ends by sending the browser to the API token’s sign-in
//  callback with the sign-in token in the address; that navigation is stopped here, so the
//  token never leaves this Mac, and the window closes once iCloud accepts it.
//
//  When the sign-in fails, Apple’s page doesn’t navigate: it reports to `window.opener`, the
//  page that would have opened it in a browser. A script stands in for that page here.
//

import AppKit
import os
import RSCore
import WebKit
import Account
import CloudKitSync

final class ICloudSignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ICloudSignIn")

	/// The sign-in page’s own website data, kept apart from the X sign-in and the article views,
	/// so Apple can recognize this Mac the next time and the sign-in lasts as long as Apple allows.
	private static let websiteDataStoreIdentifier = UUID(uuidString: "5B0B7E52-7F4D-4C8E-9A57-2F6E0C1D9A31") ?? UUID()
	private static let messageHandlerName = "netNewsListICloudSignIn"

	/// Gives Apple’s sign-in page an opener to report to, forwarding its messages to the app.
	private static let openerScript = """
	(function () {
		if (window.opener) {
			return;
		}
		var bridge = {
			postMessage: function (message) {
				try {
					window.webkit.messageHandlers.\(messageHandlerName).postMessage(JSON.stringify(message));
				} catch (error) {}
			}
		};
		try {
			Object.defineProperty(window, "opener", { value: bridge, configurable: true });
		} catch (error) {
			window.opener = bridge;
		}
	})();
	"""

	private var webView: WKWebView?
	private var isFinishingSignIn = false

	convenience init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
		window.title = NSLocalizedString("Sign In to iCloud", comment: "Window title")
		window.isReleasedWhenClosed = false
		self.init(window: window)

		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.websiteDataStoreIdentifier)
		let messageProxy = ICloudSignInMessageProxy()
		configuration.userContentController.add(messageProxy, name: Self.messageHandlerName)
		configuration.userContentController.addUserScript(WKUserScript(source: Self.openerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
		let webView = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
		webView.autoresizingMask = [.width, .height]
		webView.navigationDelegate = self
		webView.uiDelegate = self
		window.contentView = webView
		window.delegate = self
		self.webView = webView
		messageProxy.windowController = self
	}

	override func showWindow(_ sender: Any?) {
		// Each sign-in starts on a fresh page: a window shown again (iCloud ended the last sign-in)
		// still holds the last one's spent page, and Apple's sign-in address expires.
		let isOpen = window?.isVisible == true || window?.isMiniaturized == true
		super.showWindow(sender)
		if !isOpen {
			window?.center()
			Task { @MainActor in
				await loadSignInPage()
			}
		}
	}

	func windowWillClose(_ notification: Notification) {
		webView?.stopLoading()
	}

	// MARK: - WKNavigationDelegate

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		guard let url = navigationAction.request.url, let token = CloudKitWebSync.webAuthToken(inCallbackURL: url) else {
			return .allow
		}
		finishSignIn(webAuthToken: token)
		return .cancel
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		showLoadError(error)
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		showLoadError(error)
	}

	// MARK: - WKUIDelegate

	/// Opens a page the sign-in asks for in a new window (help, account recovery) in this one.
	func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
		if navigationAction.targetFrame == nil {
			webView.load(navigationAction.request)
		}
		return nil
	}
}

private extension ICloudSignInWindowController {

	/// A message Apple’s sign-in page posted to its opener: the sign-in token when the page was
	/// set up to post it, or why the sign-in failed.
	func handleSignInPageMessage(_ body: Any, from host: String) {
		guard host == "apple-cloudkit.com" || host.hasSuffix(".apple-cloudkit.com") || host.hasSuffix(".apple.com"),
			  let string = body as? String,
			  let message = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] else {
			return
		}
		if let token = message["ckSession"] as? String ?? message["ckWebAuthToken"] as? String, !token.isEmpty {
			finishSignIn(webAuthToken: token)
			return
		}
		guard let errorMessage = message["errorMessage"] as? String, errorMessage != "window closed" else {
			return
		}
		let explanation: String
		if errorMessage == "accessError" {
			explanation = NSLocalizedString("Access to iCloud data on the web is turned off for this Apple Account. On your iPhone or Mac, turn on Access iCloud Data on the Web (Settings › your name › iCloud), then try again. It can’t be turned on while Advanced Data Protection is on.", comment: "iCloud sign-in error")
		} else {
			explanation = NSLocalizedString("Apple’s sign-in page reported an authentication error. Try again; if it keeps happening, check that Advanced Data Protection is off for this Apple Account.", comment: "iCloud sign-in error")
		}
		showError(message: NSLocalizedString("Couldn’t sign in to iCloud", comment: "iCloud sign-in error"), informativeText: explanation)
	}

	func loadSignInPage() async {
		if CloudKitWebSync.shared.needsAPIToken {
			guard askForAPIToken() else {
				close()
				return
			}
		}
		do {
			let url = try await CloudKitWebSync.shared.signInURL()
			webView?.load(URLRequest(url: url))
		} catch CloudKitWebServiceError.apiTokenRejected where CloudKitWebSync.shared.isAPITokenEnteredByUser {
			// The token was typed in, so it may be the wrong one: ask for it again.
			CloudKitWebSync.shared.setAPIToken("")
			showError(message: NSLocalizedString("iCloud didn’t accept the CloudKit API token", comment: "iCloud sign-in error"), informativeText: NSLocalizedString("Check it in CloudKit Console (the container’s Tokens & Keys): it has to be the API token’s value, for the Development environment. Try Again asks for it again.", comment: "iCloud sign-in error"))
		} catch {
			showError(error, message: NSLocalizedString("Couldn’t open Apple’s sign-in page", comment: "iCloud sign-in error"))
		}
	}

	/// The build carries no CloudKit API token: asks for the one from CloudKit Console.
	func askForAPIToken() -> Bool {
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("Enter the CloudKit API Token", comment: "iCloud sign-in alert title")
		alert.informativeText = NSLocalizedString("This copy of the app doesn’t include one. Copy the API token from CloudKit Console (the container’s Tokens & Keys), for the environment your other devices use.", comment: "iCloud sign-in alert message")
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
		field.placeholderString = NSLocalizedString("API token", comment: "Text field placeholder")
		alert.accessoryView = field
		alert.window.initialFirstResponder = field
		alert.addButton(withTitle: NSLocalizedString("Continue", comment: "Continue button"))
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
		guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return false
		}
		CloudKitWebSync.shared.setAPIToken(field.stringValue)
		return !CloudKitWebSync.shared.needsAPIToken
	}

	func finishSignIn(webAuthToken: String) {
		guard !isFinishingSignIn else {
			return
		}
		isFinishingSignIn = true
		webView?.stopLoading()
		Task { @MainActor in
			defer {
				isFinishingSignIn = false
			}
			do {
				try await CloudKitWebSync.shared.completeSignIn(webAuthToken: webAuthToken)
				close()
			} catch CloudKitWebSyncError.differentAccount(let signIn) {
				askAboutDifferentAccount(signIn)
			} catch CloudKitWebServiceError.signInRequired {
				// The sign-in the page just gave was refused: there’s nothing to choose in the menu.
				Self.logger.info("ICloudSignInWindowController: iCloud refused a fresh sign-in")
				showError(message: NSLocalizedString("iCloud didn’t accept the sign-in", comment: "iCloud sign-in error"), informativeText: NSLocalizedString("iCloud refused the sign-in Apple’s page just gave this app. Try again. If it keeps happening, check that Access iCloud Data on the Web is on for this Apple Account (Settings › your name › iCloud) and that Advanced Data Protection is off.", comment: "iCloud sign-in error"))
			} catch {
				showError(error, message: NSLocalizedString("iCloud didn’t accept the sign-in", comment: "iCloud sign-in error"))
			}
		}
	}

	/// The sign-in is for another Apple Account than last time, perhaps a work account the page
	/// filled in. Using it would send this Mac’s changes to that account’s iCloud.
	func askAboutDifferentAccount(_ signIn: CloudKitWebSignIn) {
		guard let window else {
			return
		}
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = NSLocalizedString("Use a Different Apple Account?", comment: "iCloud sign-in alert title")
		alert.informativeText = NSLocalizedString("You signed in with a different Apple Account from the one this Mac used before. Your reading list is in that other account. With this one, changes you make here would go to this account’s iCloud instead.", comment: "iCloud sign-in alert message")
		alert.addButton(withTitle: NSLocalizedString("Sign In Again", comment: "Sign In Again button"))
		alert.addButton(withTitle: NSLocalizedString("Use This Account", comment: "Use This Account button"))
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
		alert.beginSheetModal(for: window) { [weak self] response in
			guard let self else {
				return
			}
			Task { @MainActor in
				switch response {
				case .alertFirstButtonReturn:
					// Forget the page’s own sign-in, so it asks for the account again.
					await self.webView?.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
					await self.loadSignInPage()
				case .alertSecondButtonReturn:
					await CloudKitWebSync.shared.adopt(signIn)
					self.close()
				default:
					self.close()
				}
			}
		}
	}

	func showLoadError(_ error: Error) {
		// Stopping the callback navigation, or loading another page, cancels the one in progress.
		let nsError = error as NSError
		if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
			return
		}
		if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
			return
		}
		guard !isFinishingSignIn else {
			return
		}
		showError(error, message: NSLocalizedString("Couldn’t load Apple’s sign-in page", comment: "iCloud sign-in error"))
	}

	func showError(_ error: Error, message: String) {
		showError(message: message, informativeText: error.localizedDescription)
	}

	func showError(message: String, informativeText: String) {
		guard let window, window.attachedSheet == nil else {
			return
		}
		let alert = NSAlert()
		alert.messageText = message
		alert.informativeText = informativeText
		alert.addButton(withTitle: NSLocalizedString("Try Again", comment: "Try Again button"))
		alert.addButton(withTitle: NSLocalizedString("Close", comment: "Close button"))
		alert.beginSheetModal(for: window) { [weak self] response in
			guard let self else {
				return
			}
			if response == .alertFirstButtonReturn {
				Task { @MainActor in
					await self.loadSignInPage()
				}
			} else {
				self.close()
			}
		}
	}
}

/// Receives the sign-in page’s messages without the web view’s content controller keeping the
/// window controller alive.
private final class ICloudSignInMessageProxy: NSObject, WKScriptMessageHandler {

	weak var windowController: ICloudSignInWindowController?

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		windowController?.handleSignInPageMessage(message.body, from: message.frameInfo.securityOrigin.host)
	}
}
