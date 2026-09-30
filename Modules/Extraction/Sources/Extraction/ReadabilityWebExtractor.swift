//
//  ReadabilityWebExtractor.swift
//  Extraction
//
//  Runs Readability.js and DOMPurify in a hidden WKWebView. The scripts live in
//  an isolated content world, and the page is parsed into an inert DOMParser
//  document, so none of the page’s own JavaScript ever runs during a normal
//  extraction. Only extractLivePage, the manual “Retry with Live Page”, loads the
//  page for real with its JavaScript on.
//

import Foundation
import WebKit
import os
import RSCore

@MainActor public final class ReadabilityWebExtractor: NSObject {

	public static let timeout: Duration = .seconds(20)

	/// How long a live page gets to finish rendering after it loads.
	static let liveSettleDelay: Duration = .milliseconds(1500)

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ReadabilityWebExtractor")
	private static let contentWorld = WKContentWorld.world(name: "NetNewsListExtraction")
	private static let blankPage = "<!doctype html><html><head></head><body></body></html>"

	/// Called with each web view the extractor creates. WebKit may throttle a web
	/// view outside a window, so the app places it, hidden, in one.
	public var webViewHost: ((WKWebView) -> Void)?

	private var staticWebView: WKWebView?
	private var isStaticWebViewReady = false
	private var liveWebView: WKWebView?
	private var navigationWaiters = [ObjectIdentifier: NavigationWaiter]()
	private var isBusy = false

	public override init() {
		super.init()
	}

	/// Extracts the readable part of `html`, fetched from `url`. The page’s scripts never run.
	public func extract(html: String, url: URL) async throws -> ExtractedPage {
		try await exclusively {
			try await self.withTimeout {
				let webView = try await self.readyStaticWebView()
				return try await self.runExtraction(in: webView, html: html, url: url)
			}
		}
	}

	/// Loads `url` in a web view with JavaScript on, lets it render, then extracts
	/// from the rendered document. For pages that build their content with scripts.
	public func extractLivePage(url: URL, userAgent: String?) async throws -> ExtractedPage {
		try await exclusively {
			defer {
				self.discardLiveWebView()
			}
			return try await self.withTimeout {
				let webView = self.makeWebView(allowsPageJavaScript: true)
				webView.customUserAgent = userAgent
				self.liveWebView = webView
				try await self.load(webView) {
					webView.load(URLRequest(url: url, timeoutInterval: PageFetcher.timeout))
				}
				try await Task.sleep(for: Self.liveSettleDelay)
				let finalURL = webView.url ?? url
				let result = try await webView.callAsyncJavaScript("return document.documentElement.outerHTML;", arguments: [:], in: nil, contentWorld: Self.contentWorld)
				guard let html = result as? String else {
					throw ExtractionError.noReadableContent
				}
				let staticWebView = try await self.readyStaticWebView()
				return try await self.runExtraction(in: staticWebView, html: html, url: finalURL)
			}
		}
	}

	/// Releases the web views, ending any extraction in progress. The next extraction creates them again.
	public func reset() {
		for waiter in navigationWaiters.values {
			waiter.finish(CancellationError())
		}
		staticWebView?.stopLoading()
		staticWebView?.removeFromSuperview()
		staticWebView = nil
		isStaticWebViewReady = false
		discardLiveWebView()
	}
}

// MARK: - WKNavigationDelegate

extension ReadabilityWebExtractor: WKNavigationDelegate {

	public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		finishNavigation(for: webView, error: nil)
	}

	public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
		finishNavigation(for: webView, error: error)
	}

	public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
		finishNavigation(for: webView, error: error)
	}

	public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		Self.logger.error("ReadabilityWebExtractor: web content process terminated")
		if webView === staticWebView {
			staticWebView = nil
			isStaticWebViewReady = false
		}
		finishNavigation(for: webView, error: ExtractionError.webContentFailed("web content process terminated"))
	}

	public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
		// Only the page itself: no pop-ups, no navigation to other pages.
		let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
		if webView === staticWebView {
			preferences.allowsContentJavaScript = false
			decisionHandler(navigationAction.navigationType == .other && isMainFrame ? .allow : .cancel, preferences)
			return
		}
		decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow, preferences)
	}
}

// MARK: - Private

private extension ReadabilityWebExtractor {

	@MainActor final class NavigationWaiter {
		var continuation: CheckedContinuation<Void, any Error>?

		func finish(_ error: (any Error)?) {
			guard let continuation else {
				return
			}
			self.continuation = nil
			if let error {
				continuation.resume(throwing: error)
			} else {
				continuation.resume()
			}
		}
	}

	@MainActor final class Once {
		var isDone = false
	}

	static let userScripts: [WKUserScript] = {
		["Readability", "purify.min", "extract"].compactMap { name in
			guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "JavaScript"),
				  let source = try? String(contentsOf: url, encoding: .utf8) else {
				logger.fault("ReadabilityWebExtractor: missing script \(name, privacy: .public)")
				return nil
			}
			return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
		}
	}()

	func exclusively<T>(_ operation: () async throws -> T) async throws -> T {
		guard !isBusy else {
			throw ExtractionError.busy
		}
		isBusy = true
		defer {
			isBusy = false
		}
		return try await operation()
	}

	/// Runs `operation`, giving up after `timeout`. On timeout the web views are
	/// discarded, which ends whatever WebKit was still doing.
	func withTimeout<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
		let once = Once()
		var work: Task<Void, Never>?
		var timer: Task<Void, Never>?
		defer {
			work?.cancel()
			timer?.cancel()
		}
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
			work = Task { @MainActor in
				do {
					let value = try await operation()
					guard !once.isDone else {
						return
					}
					once.isDone = true
					continuation.resume(returning: value)
				} catch {
					guard !once.isDone else {
						return
					}
					once.isDone = true
					continuation.resume(throwing: error)
				}
			}
			timer = Task { @MainActor in
				try? await Task.sleep(for: Self.timeout)
				guard !Task.isCancelled, !once.isDone else {
					return
				}
				once.isDone = true
				Self.logger.info("ReadabilityWebExtractor: timed out")
				self.reset()
				continuation.resume(throwing: ExtractionError.timedOut)
			}
		}
	}

	func makeWebView(allowsPageJavaScript: Bool) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsPageJavaScript
		configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
		configuration.mediaTypesRequiringUserActionForPlayback = .all
		for script in Self.userScripts {
			configuration.userContentController.addUserScript(script)
		}
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
		webView.navigationDelegate = self
		webViewHost?(webView)
		return webView
	}

	func readyStaticWebView() async throws -> WKWebView {
		if let staticWebView, isStaticWebViewReady {
			return staticWebView
		}
		let webView = makeWebView(allowsPageJavaScript: false)
		staticWebView = webView
		try await load(webView) {
			webView.loadHTMLString(Self.blankPage, baseURL: nil)
		}
		isStaticWebViewReady = true
		return webView
	}

	func load(_ webView: WKWebView, start: () -> Void) async throws {
		let waiter = NavigationWaiter()
		let key = ObjectIdentifier(webView)
		navigationWaiters[key] = waiter
		defer {
			navigationWaiters[key] = nil
		}
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				waiter.continuation = continuation
				start()
			}
		} onCancel: {
			Task { @MainActor in
				waiter.finish(CancellationError())
			}
		}
	}

	func finishNavigation(for webView: WKWebView, error: (any Error)?) {
		navigationWaiters[ObjectIdentifier(webView)]?.finish(error)
	}

	func runExtraction(in webView: WKWebView, html: String, url: URL) async throws -> ExtractedPage {
		let result: Any?
		do {
			result = try await webView.callAsyncJavaScript("return netNewsListExtract(html, url);", arguments: ["html": html, "url": url.absoluteString], in: nil, contentWorld: Self.contentWorld)
		} catch {
			Self.logger.error("ReadabilityWebExtractor: script failed: \(error.localizedDescription, privacy: .public)")
			throw ExtractionError.webContentFailed(error.localizedDescription)
		}
		guard let dictionary = result as? [String: Any] else {
			throw ExtractionError.noReadableContent
		}
		return Self.page(from: dictionary, url: url)
	}

	static func page(from dictionary: [String: Any], url: URL) -> ExtractedPage {
		func string(_ key: String) -> String? {
			guard let value = dictionary[key] as? String else {
				return nil
			}
			let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
		let textLength = (dictionary["textLength"] as? NSNumber)?.intValue ?? 0
		return ExtractedPage(url: url,
							 title: string("title"),
							 byline: string("byline"),
							 contentHTML: string("content"),
							 textLength: textLength,
							 excerpt: string("excerpt"),
							 siteName: string("siteName"),
							 language: string("lang"),
							 publishedTime: string("publishedTime"),
							 leadImageURL: string("leadImage"))
	}

	func discardLiveWebView() {
		liveWebView?.stopLoading()
		liveWebView?.removeFromSuperview()
		if let liveWebView {
			finishNavigation(for: liveWebView, error: CancellationError())
		}
		liveWebView = nil
	}
}
