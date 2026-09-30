//
//  AccountManager.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/18/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os
import RSCore
import RSWeb
import Articles
import ArticlesDatabase
import ErrorLog
import ActivityLog

@MainActor public final class AccountManager: UnreadCountProvider {

	public static var shared = AccountManager()

	public let defaultAccount: Account
	public let errorLogDatabase: ErrorLogDatabase

	private var accountsDictionary = [String: Account]()

	private var lastStatusRepairDate: Date?
	private static let statusRepairInterval: TimeInterval = 1 * 60 * 60

	public var isSuspended = false

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AccountManager")

	public var areUnreadCountsInitialized: Bool {
		for account in activeAccounts {
			if !account.areUnreadCountsInitialized {
				return false
			}
		}
		return true
	}

	public var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
				postUnreadCountDidChangeNotification()
			}
		}
	}

	public var accounts: [Account] {
		Array(accountsDictionary.values)
	}

	public var sortedAccounts: [Account] {
		sortByName(accounts)
	}

	public var iCloudAccount: Account? {
		defaultAccount
	}

	public var hasiCloudAccount: Bool {
		true
	}

	public var activeAccounts: [Account] {
		assert(Thread.isMainThread)
		return Array(accountsDictionary.values.filter { $0.isActive })
	}

	/// Repair article statuses in all active accounts, at most once per interval.
	public func repairStatusesIfNeeded() {
		if let lastStatusRepairDate, Date().timeIntervalSince(lastStatusRepairDate) < Self.statusRepairInterval {
			return
		}
		lastStatusRepairDate = Date()
		for account in activeAccounts {
			account.repairStatuses()
		}
	}

	public var sortedActiveAccounts: [Account] {
		sortByName(activeAccounts)
	}

	public var lastRefreshCompletedDate: Date? {
		var lastRefreshCompletedDate: Date?
		for account in activeAccounts {
			if let accountLastArticleFetchEndTime = account.lastRefreshCompletedDate {
				if lastRefreshCompletedDate == nil || lastRefreshCompletedDate! < accountLastArticleFetchEndTime {
					lastRefreshCompletedDate = accountLastArticleFetchEndTime
				}
			}
		}
		return lastRefreshCompletedDate
	}

	public func existingActiveAccount(forDisplayName displayName: String) -> Account? {
		AccountManager.shared.activeAccounts.first(where: { $0.nameForDisplay == displayName })
	}

	public var refreshInProgress: Bool {
		for account in activeAccounts {
			if account.refreshInProgress {
				return true
			}
		}
		return false
	}

	private var isActive = false

	public init() {
		// The one iCloud account always exists. It syncs whenever the device is signed in to iCloud.
		let accountsFolder = AppConfig.dataSubfolder(named: "Accounts").path
		let accountID = "iCloud"
		let accountFolder = (accountsFolder as NSString).appendingPathComponent("\(AccountType.cloudKit.rawValue)_\(accountID)")
		do {
			try FileManager.default.createDirectory(atPath: accountFolder, withIntermediateDirectories: true, attributes: nil)
		} catch {
			assertionFailure("Could not create folder for the iCloud account.")
			abort()
		}

		let errorLogDatabasePath = AppConfig.dataFolder.appendingPathComponent("Errors.db").path
		self.errorLogDatabase = ErrorLogDatabase(databasePath: errorLogDatabasePath)

		defaultAccount = Account(dataFolder: accountFolder, type: .cloudKit, accountID: accountID)
		accountsDictionary[defaultAccount.accountID] = defaultAccount

	}

	public func start() {
		guard !isActive else {
			assertionFailure("start called when isActive is already true")
			return
		}
		isActive = true

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidInitialize(_:)), name: .UnreadCountDidInitialize, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(accountStateDidChange(_:)), name: .AccountStateDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidGoToBackground(_:)), name: .appDidGoToBackground, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
		DispatchQueue.main.async {
			self.updateUnreadCount()
		}
	}

	// MARK: - API

	public func existingAccount(accountID: String) -> Account? {
		return accountsDictionary[accountID]
	}

	public func existingContainer(with containerID: ContainerIdentifier) -> Container? {
		switch containerID {
		case .account(let accountID):
			return existingAccount(accountID: accountID)
		case .folder(let accountID, let folderName):
			return existingAccount(accountID: accountID)?.existingFolder(with: folderName)
		default:
			break
		}
		return nil
	}

	public func existingFeed(with sidebarItemID: SidebarItemIdentifier) -> SidebarItem? {
		switch sidebarItemID {
		case .folder(let accountID, let folderName):
			if let account = existingAccount(accountID: accountID) {
				return account.existingFolder(with: folderName)
			}
		case .feed(let accountID, let feedID):
			if let account = existingAccount(accountID: accountID) {
				return account.existingFeed(withFeedID: feedID)
			}
		default:
			break
		}
		return nil
	}

	public func suspendNetworkAll() {
		isSuspended = true
		for account in accounts {
			account.suspendNetwork()
		}
	}

	public func resumeAll() {
		isSuspended = false
		for account in accounts {
			account.resumeDelegate()
		}
		for account in accounts {
			account.resume()
		}
	}

	public func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async {
		for account in activeAccounts {
			await account.receiveRemoteNotification(userInfo: userInfo)
		}
	}

	public typealias ErrorHandlerCallback = @Sendable (Error) -> Void

	public func refreshAllWithoutWaiting(errorHandler: ErrorHandlerCallback? = nil) {
		Task {
			await refreshAll(errorHandler: errorHandler)
		}
	}

	/// Returns `true` if the refresh ran, `false` if it was skipped
	/// due to no network connection.
	@discardableResult
	public func refreshAll(errorHandler: ErrorHandlerCallback? = nil) async -> Bool {
		guard NetworkMonitor.shared.isConnected else {
			Self.logger.info("AccountManager: skipping refreshAll — not connected to internet.")
			return false
		}

		CombinedRefreshProgress.shared.start()
		defer {
			CombinedRefreshProgress.shared.stop()
		}

		await withTaskGroup(of: Void.self, isolation: MainActor.shared) { group in
			for account in activeAccounts {
				group.addTask {
					do {
						try await account.refreshAll()
					} catch {
						errorHandler?(error)
					}
				}
			}
		}

		return true
	}

	public func sendArticleStatusAll() async {
		await withTaskGroup(of: Void.self, isolation: MainActor.shared) { group in
			for account in activeAccounts {
				group.addTask {
					try? await account.sendArticleStatus()
				}
			}
		}
	}

	public func syncArticleStatusAllWithoutWaiting() {
		Task {
			await syncArticleStatusAll()
		}
	}

	/// Returns `true` if any account reported meaningful work this round;
	/// `false` only if every account was idle.
	@discardableResult
	public func syncArticleStatusAll() async -> Bool {
		await withTaskGroup(of: Bool.self, isolation: MainActor.shared) { group in
			for account in activeAccounts {
				group.addTask {
					(try? await account.syncArticleStatus()) ?? false
				}
			}

			var anyWork = false
			for await didWork in group {
				if didWork {
					anyWork = true
				}
			}
			return anyWork
		}
	}

	public func saveAll() {
		for account in accounts {
			account.save()
		}
	}

	public func saveAllIfNeeded() {
		for account in accounts {
			account.saveIfNeeded()
		}
	}

	// MARK: - Fetching Articles

	// These fetch articles from active accounts and return a merged Set<Article>.

	public func fetchArticles(_ fetchType: FetchType) -> Set<Article> {
		precondition(Thread.isMainThread)

		var articles = Set<Article>()
		for account in activeAccounts {
			articles.formUnion(account.fetchArticles(fetchType))
		}
		return articles
	}

	public func fetchArticlesAsync(_ fetchType: FetchType) async -> Set<Article> {
		precondition(Thread.isMainThread)

		guard activeAccounts.count > 0 else {
			return Set<Article>()
		}

		var allFetchedArticles = Set<Article>()
		for account in activeAccounts {
			let articles = await account.fetchArticlesAsync(fetchType)
			allFetchedArticles.formUnion(articles)
		}

		return allFetchedArticles
	}

	/// Fetch a single article (synchronously) by accountID and articleID.
	public func fetchArticle(accountID: String, articleID: String) -> Article? {
		precondition(Thread.isMainThread)

		guard let account = existingAccount(accountID: accountID) else {
			return nil
		}

		let articles = account.fetchArticles(.articleIDs(Set([articleID])))
		return articles.first
	}

	// MARK: - Fetching Article Counts

	public func fetchCountForStarredArticles() -> Int {
		precondition(Thread.isMainThread)
		var count = 0
		for account in activeAccounts {
			count += account.fetchCountForStarredArticles()
		}
		return count
	}

	public func fetchCountForStarredArticlesAsync() async -> Int {
		precondition(Thread.isMainThread)
		var count = 0
		for account in activeAccounts {
			count += await account.fetchCountForStarredArticlesAsync()
		}
		return count
	}

	public func fetchCountForTodayArticlesAsync() async -> Int {
		precondition(Thread.isMainThread)
		var count = 0
		for account in activeAccounts {
			count += await account.fetchCountForTodayArticlesAsync()
		}
		return count
	}

	public func fetchUnreadCountForTodayAsync() async -> Int {
		precondition(Thread.isMainThread)
		var count = 0
		for account in activeAccounts {
			count += await account.fetchUnreadCountForTodayAsync()
		}
		return count
	}

	// MARK: - Vacuum

	public func vacuumAccountDatabases() async {
		for account in accounts {
			await account.vacuumDatabases()
		}
	}

	// MARK: - Caches

	/// Empty caches that can reasonably be emptied — when the app moves to the background, for instance.
	public func emptyCaches() {
		for account in accounts {
			account.emptyCaches()
		}
	}

	// MARK: - Notifications

	@objc func unreadCountDidInitialize(_ notification: Notification) {
		guard notification.object is Account else {
			return
		}
		if areUnreadCountsInitialized {
			postUnreadCountDidInitializeNotification()
		}
	}

	@objc func unreadCountDidChange(_ notification: Notification) {
		guard notification.object is Account else {
			return
		}
		updateUnreadCount()
	}

	@objc func accountStateDidChange(_ notification: Notification) {
		updateUnreadCount()
	}

	@objc func handleLowMemory(_ notification: Notification) {
		emptyCaches()
	}

	@objc func handleAppDidGoToBackground(_ notification: Notification) {
		emptyCaches()
	}
}

// MARK: - Private

private extension AccountManager {

	func updateUnreadCount() {
		unreadCount = calculateUnreadCount(activeAccounts)
	}

	func sortByName(_ accounts: [Account]) -> [Account] {

		return accounts.sorted { (account1, account2) -> Bool in
			if account1 === defaultAccount {
				return true
			}
			if account2 === defaultAccount {
				return false
			}
			return (account1.nameForDisplay as NSString).localizedStandardCompare(account2.nameForDisplay) == .orderedAscending
		}
	}
}
