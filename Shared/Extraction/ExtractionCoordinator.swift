//
//  ExtractionCoordinator.swift
//  NetNewsList
//
//  Turns saved URLs into readable, offline copies: one fetch and one Readability
//  pass per article, one article at a time, only while the app is in the
//  foreground. Pending articles (no body yet) are picked up on launch, on
//  foreground and after every iCloud fetch, so an article saved elsewhere is
//  extracted by whichever device sees it first. See Technotes/NetNewsList/Plan.md,
//  D2 and D3.
//

import Foundation
import os
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RSCore
import RSWeb
import Articles
import Account
import Extraction

extension Notification.Name {
	/// userInfo[Account.UserInfoKey.articleIDs] is the Set<String> of affected article IDs,
	/// the same shape as StatusesDidChange, so the timelines reload those cells the same way.
	static let ExtractionStateDidChange = Notification.Name("ExtractionStateDidChange")
}

extension Notification {

	/// The article IDs named by ExtractionStateDidChange, StatusesDidChange or AccountDidDownloadArticles.
	var affectedArticleIDs: Set<String> {
		var articleIDs = userInfo?[Account.UserInfoKey.articleIDs] as? Set<String> ?? Set<String>()
		for key in [Account.UserInfoKey.newArticles, Account.UserInfoKey.updatedArticles] {
			if let articles = userInfo?[key] as? Set<Article> {
				articleIDs.formUnion(articles.map(\.articleID))
			}
		}
		return articleIDs
	}
}

@MainActor final class ExtractionCoordinator {

	static let shared = ExtractionCoordinator()

	enum State: Equatable {
		case pending
		case extracting
		case failed(String)
	}

	fileprivate struct Job {
		let articleID: String
		let usesLivePage: Bool
		let isManual: Bool
	}

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "Extraction")

	private let fetcher = PageFetcher()
	private let extractor = ReadabilityWebExtractor()
	private var ledger = ExtractionLedger()
	private var ledgerFileURL: URL?
	private var jobs = [Job]()
	private var currentJob: Job?
	private var currentTask: Task<Void, Never>?
	private var isStarted = false
	private var isSuspended = false
	private var isDrainScheduled = false

	private var account: Account {
		AccountManager.shared.defaultAccount
	}

	/// Call once at launch, after the account is set up.
	func start() {
		guard !isStarted else {
			return
		}
		isStarted = true

		let fileURL = URL(fileURLWithPath: account.dataFolder).appendingPathComponent("ExtractionLedger.json")
		ledgerFileURL = fileURL
		ledger = ExtractionLedger.load(from: fileURL)
		extractor.webViewHost = { webView in
			Self.host(webView)
		}

		NotificationCenter.default.addObserver(self, selector: #selector(accountDidDownloadArticles(_:)), name: .AccountDidDownloadArticles, object: nil)
#if os(macOS)
		NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
#else
		NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
#endif

		scheduleDrain()
	}

	// MARK: - API

	/// Saves a page to the reading list and starts extracting it.
	@discardableResult
	func saveArticle(url urlString: String, title: String?) async throws -> Article {
		let article = try await account.saveArticle(url: urlString, title: title, content: nil)
		if article.contentHTML == nil {
			enqueue(Job(articleID: article.articleID, usesLivePage: false, isManual: false))
		}
		return article
	}

	/// Extracts these articles again now, replacing their stored body when the page yields one.
	/// With `usesLivePage`, the page is loaded with its JavaScript on first.
	func retry(articleIDs: Set<String>, usesLivePage: Bool) {
		for articleID in articleIDs {
			ledger.remove(articleID)
			enqueue(Job(articleID: articleID, usesLivePage: usesLivePage, isManual: true))
		}
		saveLedger()
	}

	/// The extraction state to show for an article, or nil when it has a body and nothing is in progress.
	func state(for article: Article) -> State? {
		let articleID = article.articleID
		if currentJob?.articleID == articleID {
			return .extracting
		}
		if jobs.contains(where: { $0.articleID == articleID }) {
			return .pending
		}
		guard article.contentHTML == nil else {
			return nil
		}
		if let message = ledger.failureMessage(for: articleID) {
			return .failed(message)
		}
		return .pending
	}

	/// A short line for the timeline in place of the article summary, or nil.
	func statusText(for article: Article) -> String? {
		switch state(for: article) {
		case .pending:
			return NSLocalizedString("Waiting to save the page…", comment: "Timeline: extraction pending")
		case .extracting:
			return NSLocalizedString("Saving the page…", comment: "Timeline: extraction in progress")
		case .failed(let message):
			return String(format: NSLocalizedString("Couldn’t save the page: %@", comment: "Timeline: extraction failed"), message)
		case nil:
			return nil
		}
	}

	/// The body shown for an article whose page hasn’t been saved yet.
	func placeholderHTML(for article: Article) -> String {
		let message: String
		switch state(for: article) {
		case .failed(let error):
			message = String(format: NSLocalizedString("This page couldn’t be saved for offline reading: %@ Use Retry Saving Page to try again.", comment: "Article view: extraction failed"), error)
		default:
			message = NSLocalizedString("This page hasn’t been saved for offline reading yet. It will be saved the next time NetNewsList is open and online.", comment: "Article view: extraction pending")
		}
		var html = "<p class=\"systemMessage\">\(message.escapingSpecialXMLCharacters)</p>"
		if let link = article.preferredLink {
			let label = NSLocalizedString("Open the original page", comment: "Article view: link to the live page")
			html += "\n<p><a href=\"\(link.escapingSpecialXMLCharacters)\">\(label.escapingSpecialXMLCharacters)</a></p>"
		}
		return html
	}
}

// MARK: - Notifications

private extension ExtractionCoordinator {

	@objc func accountDidDownloadArticles(_ note: Notification) {
		scheduleDrain()
	}

	@objc func appDidBecomeActive(_ note: Notification) {
		isSuspended = false
		scheduleDrain()
		runNextJobIfIdle()
	}

	/// WebKit stops running JavaScript in the background, so put the current job back and wait.
	@objc func appDidEnterBackground(_ note: Notification) {
		isSuspended = true
		guard let currentJob, let currentTask else {
			return
		}
		Self.logger.info("Extraction: pausing \(currentJob.articleID, privacy: .public) in the background")
		jobs.insert(currentJob, at: 0)
		currentTask.cancel()
		extractor.reset()
	}
}

// MARK: - Queue

private extension ExtractionCoordinator {

	func scheduleDrain() {
		guard isStarted, !isDrainScheduled else {
			return
		}
		isDrainScheduled = true
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(1))
			self.isDrainScheduled = false
			await self.drainPending()
		}
	}

	/// Queues every pending article this device may try now.
	func drainPending() async {
		guard !isSuspended else {
			return
		}
		let pendingArticleIDs = await account.pendingExtractionArticleIDs()
		let ledgerBeforePruning = ledger
		ledger.prune(keeping: pendingArticleIDs)
		if ledger != ledgerBeforePruning {
			saveLedger()
		}
		let now = Date()
		for articleID in pendingArticleIDs.sorted() where ledger.allowsAutomaticAttempt(for: articleID, at: now) {
			enqueue(Job(articleID: articleID, usesLivePage: false, isManual: false))
		}
	}

	func enqueue(_ job: Job) {
		if let currentJob, currentJob.articleID == job.articleID, !job.isManual {
			return
		}
		if let index = jobs.firstIndex(where: { $0.articleID == job.articleID }) {
			if job.isManual {
				jobs[index] = job
			}
			return
		}
		jobs.append(job)
		postStateChange(job.articleID)
		runNextJobIfIdle()
	}

	func runNextJobIfIdle() {
		guard currentTask == nil, !isSuspended, !jobs.isEmpty else {
			return
		}
		let job = jobs.removeFirst()
		currentJob = job
		postStateChange(job.articleID)
		currentTask = Task { @MainActor in
			await self.perform(job)
			self.currentJob = nil
			self.currentTask = nil
			self.postStateChange(job.articleID)
			self.runNextJobIfIdle()
		}
	}

	func perform(_ job: Job) async {
		guard let article = await account.fetchArticlesAsync(.articleIDs([job.articleID])).first else {
			ledger.remove(job.articleID)
			saveLedger()
			return
		}
		guard job.isManual || article.contentHTML == nil else {
			return
		}
		guard let link = article.rawExternalLink ?? article.rawLink, let url = URL(string: link) else {
			recordFailure(job.articleID, error: ExtractionError.unsupportedURL)
			return
		}

		let userAgent = UserAgent.browserUserAgent
		var page: ExtractedPage?
		do {
			if job.usesLivePage {
				page = try await extractor.extractLivePage(url: url, userAgent: userAgent)
			} else {
				let fetchedPage = try await fetcher.fetch(url, userAgent: userAgent)
				page = try await extractor.extract(html: fetchedPage.html, url: fetchedPage.url)
			}
			guard let page, page.hasReadableContent else {
				throw ExtractionError.noReadableContent
			}
			let content = ReadingListContent(title: article.title == nil ? page.title : nil,
											 contentHTML: ExtractedContentFormatter.storedHTML(for: page),
											 summary: page.excerpt,
											 imageURL: page.leadImageURL,
											 byline: page.byline)
			try await account.updateArticleContent(articleID: job.articleID, content: content)
			ledger.remove(job.articleID)
			saveLedger()
			Self.logger.info("Extraction: saved \(job.articleID, privacy: .public) (\(page.textLength) characters)")
		} catch {
			guard !Task.isCancelled else {
				return
			}
			recordFailure(job.articleID, error: error)
			// Keep what little the page offered: its title, when the article has none.
			if article.title == nil, let title = page?.title {
				try? await account.updateArticleContent(articleID: job.articleID, content: ReadingListContent(title: title))
			}
		}
	}

	func recordFailure(_ articleID: String, error: any Error) {
		Self.logger.error("Extraction: failed \(articleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
		ledger.recordFailure(for: articleID, message: error.localizedDescription, at: Date())
		saveLedger()
	}

	func saveLedger() {
		guard let ledgerFileURL else {
			return
		}
		do {
			try ledger.save(to: ledgerFileURL)
		} catch {
			Self.logger.error("Extraction: couldn’t save the ledger: \(error.localizedDescription, privacy: .public)")
		}
	}

	func postStateChange(_ articleID: String) {
		NotificationCenter.default.post(name: .ExtractionStateDidChange, object: self, userInfo: [Account.UserInfoKey.articleIDs: Set([articleID])])
	}

	/// WebKit may throttle a web view outside a window. On iOS, keep it in the
	/// key window, behind everything and invisible. On the Mac the window’s content
	/// view is a split view, which would treat another subview as a pane, so the web
	/// view stays windowless there.
	static func host(_ webView: WKWebView) {
#if os(iOS)
		let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
		guard let window = windows.first else {
			return
		}
		webView.alpha = 0
		webView.isUserInteractionEnabled = false
		window.insertSubview(webView, at: 0)
#endif
	}
}
