//
//  ICloudSignInRenewer.swift
//  NetNewsList
//
//  Renews the iCloud web sign-in without the user when Apple allows it. Apple’s sign-in page
//  keeps its own website data between sign-ins (`ICloudSignInPage`), so when it still
//  recognizes this Mac it goes straight to the callback with a fresh token and nothing to
//  fill in. This loads the page out of sight and takes that token; when the page wants the
//  user instead (a password, a code, an error), the caller shows the sign-in window as before.
//

import AppKit
import os
import RSCore
import WebKit
import Account
import CloudKitSync

@MainActor final class ICloudSignInRenewer: NSObject, WKNavigationDelegate {

	static let shared = ICloudSignInRenewer()

	enum Outcome {
		/// A fresh sign-in is in place.
		case renewed
		/// Apple’s page needs the user: show the sign-in window.
		case needsUser
		/// The page gave a sign-in for another Apple Account; the window asks about it.
		case differentAccount(CloudKitWebSignIn)
		/// Too soon after the last attempt, or one is running.
		case skipped
	}

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ICloudSignIn")
	/// How long the page gets to reach the callback by itself.
	private static let timeout: Duration = .seconds(25)
	/// The least time between attempts, so a page that keeps wanting the user isn’t loaded over and over.
	private static let minimumGap: TimeInterval = 60 * 60
	/// A sign-in made with Keep me signed in lasts two weeks; renew it from the tenth day.
	private static let renewalAge: TimeInterval = 10 * 24 * 60 * 60

	private var webView: WKWebView?
	private var messageProxy: ICloudSignInMessageProxy?
	private var continuation: CheckedContinuation<Outcome, Never>?
	private var lastAttempt: Date?
	private var isRunning = false

	/// Whether the current sign-in is old enough to renew before Apple ends it.
	var isRenewalDue: Bool {
		guard CloudKitWebSync.shared.isSignedIn, let signInDate = CloudKitWebSync.shared.signInDate else {
			return false
		}
		return Date().timeIntervalSince(signInDate) > Self.renewalAge
	}

	/// Tries to sign in again without the user. `force` ignores the gap since the last attempt
	/// (iCloud just ended the sign-in, so this is the one chance to keep syncing unnoticed).
	func renew(force: Bool = false) async -> Outcome {
		guard !isRunning, CloudKitWebSync.isEnabled, !CloudKitWebSync.shared.needsAPIToken else {
			return isRunning ? .skipped : .needsUser
		}
		if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.minimumGap {
			return .skipped
		}
		isRunning = true
		lastAttempt = Date()
		defer {
			isRunning = false
			webView?.stopLoading()
			webView = nil
			messageProxy = nil
		}

		let url: URL
		do {
			url = try await CloudKitWebSync.shared.signInURL()
		} catch {
			Self.logger.error("ICloudSignInRenewer: couldn’t get Apple’s sign-in page: \(error.localizedDescription, privacy: .public)")
			return .needsUser
		}

		let proxy = ICloudSignInMessageProxy()
		let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 720), configuration: ICloudSignInPage.makeConfiguration(messageHandler: proxy))
		webView.navigationDelegate = self
		proxy.handler = { [weak self] body, host in
			self?.handlePageMessage(body, from: host)
		}
		self.webView = webView
		messageProxy = proxy

		let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
			self.continuation = continuation
			webView.load(URLRequest(url: url))
			Task { @MainActor [weak self] in
				try? await Task.sleep(for: Self.timeout)
				self?.finish(with: .needsUser, reason: "the page didn’t finish by itself")
			}
		}
		return outcome
	}

	// MARK: - WKNavigationDelegate

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		guard let url = navigationAction.request.url, let token = CloudKitWebSync.webAuthToken(inCallbackURL: url) else {
			return .allow
		}
		complete(webAuthToken: token)
		return .cancel
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		didFail(error)
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		didFail(error)
	}
}

private extension ICloudSignInRenewer {

	func handlePageMessage(_ body: Any, from host: String) {
		switch ICloudSignInPage.message(body, from: host) {
		case .token(let token):
			complete(webAuthToken: token)
		case .error(let errorMessage):
			finish(with: .needsUser, reason: "the page reported \(errorMessage)")
		case nil:
			break
		}
	}

	func didFail(_ error: Error) {
		let nsError = error as NSError
		// Stopping the callback navigation cancels the one in progress.
		if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
			return
		}
		if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
			return
		}
		finish(with: .needsUser, reason: "the page didn’t load: \(error.localizedDescription)")
	}

	func complete(webAuthToken: String) {
		guard continuation != nil else {
			return
		}
		webView?.stopLoading()
		Task { @MainActor in
			do {
				try await CloudKitWebSync.shared.completeSignIn(webAuthToken: webAuthToken)
				Self.logger.notice("ICloudSignInRenewer: renewed the iCloud sign-in without the user")
				finish(with: .renewed, reason: nil)
			} catch CloudKitWebSyncError.differentAccount(let signIn) {
				finish(with: .differentAccount(signIn), reason: "the page signed in to a different Apple Account")
			} catch {
				finish(with: .needsUser, reason: "iCloud didn’t accept the page’s sign-in: \(error.localizedDescription)")
			}
		}
	}

	func finish(with outcome: Outcome, reason: String?) {
		guard let continuation else {
			return
		}
		self.continuation = nil
		if let reason {
			Self.logger.notice("ICloudSignInRenewer: the sign-in needs the user: \(reason, privacy: .public)")
		}
		continuation.resume(returning: outcome)
	}
}
