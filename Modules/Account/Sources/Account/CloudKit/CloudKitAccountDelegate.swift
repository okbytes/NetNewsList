//
//  CloudKitAppDelegate.swift
//  Account
//
//  Created by Maurice Parker on 3/18/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import CloudKit
import ErrorLog
import SystemConfiguration
import os
import ActivityLog
import RSCore
import RSParser
import RSWeb
import SyncDatabase
import Articles
import ArticlesDatabase
import CloudKitSync

/// Parameters: (error, operation, fileName, functionName, lineNumber)
typealias CloudKitSyncErrorHandler = @Sendable (Error, String, String, String, Int) -> Void

enum CloudKitAccountDelegateError: LocalizedError, Sendable {
	case invalidParameter
	case unknown

	var errorDescription: String? {
		return NSLocalizedString("An unexpected CloudKit error occurred.", comment: "An unexpected CloudKit error occurred.")
	}
}

@MainActor final class CloudKitAccountDelegate: AccountDelegate {
	nonisolated private static let logger = cloudKitLogger

	private let syncDatabase: SyncDatabase

	// Created on first use: making a CKContainer in a process without the iCloud
	// entitlement (unit tests, unsigned builds) traps.
	private lazy var container: CKContainer = {
		guard let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String else {
			preconditionFailure("Info.plist is missing CloudKitContainerIdentifier")
		}
		return CKContainer(identifier: identifier)
	}()

	private lazy var accountZone = CloudKitAccountZone(container: container)
	private lazy var articlesZone = CloudKitArticlesZone(container: container)

	private let mainThreadOperationQueue = MainThreadOperationQueue()
	private var syncErrorHandler: CloudKitSyncErrorHandler?

	private var lastNoChangeSyncDate: Date?
	private static let noChangeBackoffInterval: TimeInterval = 30 * 60

	// Set when CKContainer reports the iCloud account isn’t available — signed out,
	// restricted, or paused pending Terms and Conditions acceptance. While set, iCloud
	// stages are skipped and one Error Log entry is posted.
	// Cleared when the system posts CKAccountChanged.
	// <https://github.com/Ranchero-Software/NetNewsWire/issues/4115>
	private var iCloudAccountIsUnavailable = false

	weak var account: Account?

	/// CloudKit is never touched under unit tests: the test process has no iCloud entitlement.
	private var isCloudKitEnabled: Bool {
		!Platform.isRunningUnitTests
	}

	let behaviors: AccountBehaviors = []
	let isOPMLImportInProgress = false

	var accountSettings: AccountSettings?

	var progressInfo = ProgressInfo() {
		didSet {
			if progressInfo != oldValue {
				postProgressInfoDidChangeNotification()
			}
		}
	}

	private let syncProgress = RSProgress()
	private var syncProgressInfo = ProgressInfo() {
		didSet {
			updateProgress()
		}
	}

	init(dataFolder: String) {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		let databaseFilePath = (dataFolder as NSString).appendingPathComponent("Sync.sqlite3")
		self.syncDatabase = SyncDatabase(databasePath: databaseFilePath)


		NotificationCenter.default.addObserver(self, selector: #selector(syncProgressDidChange(_:)), name: .progressInfoDidChange, object: syncProgress)
		NotificationCenter.default.addObserver(self, selector: #selector(handleCKAccountChanged(_:)), name: .CKAccountChanged, object: nil)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	// CKAccountChanged can arrive on any thread.
	@objc nonisolated func handleCKAccountChanged(_ note: Notification) {
		Task { @MainActor in
			let wasUnavailable = iCloudAccountIsUnavailable
			iCloudAccountIsUnavailable = false
			if wasUnavailable {
				Self.logger.info("CloudKitAccountDelegate: iCloud account changed — refreshing")
				try? await refreshAll()
			}
		}
	}

	func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async {
		guard let account, isCloudKitEnabled else {
			return
		}
		lastNoChangeSyncDate = nil
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		ActivityLog.shared.logCompletedActivity(owner: account.activityOwner, kind: .receiveCloudKitNotification)

		await withCheckedContinuation { continuation in
			let op = CloudKitRemoteNotificationOperation(accountZone: accountZone, articlesZone: articlesZone, accountID: account.accountID, accountDisplayName: account.nameForDisplay, userInfo: userInfo)
			op.completionBlock = { _ in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				continuation.resume()
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func refreshAll() async throws {
		guard let account, isCloudKitEnabled else {
			return
		}
		guard syncProgressInfo.isComplete else {
			return
		}

		syncProgress.reset()

		guard NetworkMonitor.shared.isConnected else {
			return
		}

		// When the iCloud account is unavailable, skip syncing — no doomed
		// CloudKit requests, no modal alert. CKAccountChanged resumes syncing.
		if let unavailableError = await iCloudAccountUnavailableError() {
			if !iCloudAccountIsUnavailable {
				iCloudAccountIsUnavailable = true
				account.postSyncError(unavailableError, operation: "Refreshing account")
			}
			return
		}
		iCloudAccountIsUnavailable = false

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		try await standardRefreshAll(for: account)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func syncArticleStatus() async throws -> Bool {
		guard let account, isCloudKitEnabled else {
			return false
		}
		guard !iCloudAccountIsUnavailable else {
			return false
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		if let lastNoChangeSyncDate, Date().timeIntervalSince(lastNoChangeSyncDate) < Self.noChangeBackoffInterval {
			Self.logger.debug("CloudKitAccountDelegate: Skipping sync — no changes on last check, backing off")
			return false
		}

		let sendResult = try await sendArticleStatus(account: account, showProgress: false)
		try await refreshArticleStatus()

		let didReceiveChanges = !(articlesZoneHasNoChanges && accountZoneHasNoChanges)
		let didWork = sendResult.sentCount > 0 || didReceiveChanges

		// A failed send means statuses are still waiting to go out, so this isn't a quiet
		// period. Backing off here would also skip receiving for the next half hour.
		if didWork || sendResult.didFail {
			lastNoChangeSyncDate = nil
		} else {
			lastNoChangeSyncDate = Date()
		}

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		return didWork
	}

	private var articlesZoneHasNoChanges: Bool {
		guard let delegate = articlesZone.delegate as? CloudKitArticlesZoneDelegate else {
			return true
		}
		return delegate.lastChangedCount == 0 && delegate.lastDeletedCount == 0
	}

	private var accountZoneHasNoChanges: Bool {
		guard let delegate = accountZone.delegate as? CloudKitAcountZoneDelegate else {
			return true
		}
		return delegate.lastChangedCount == 0 && delegate.lastDeletedCount == 0
	}

	func sendArticleStatus() async throws {
		guard let account, isCloudKitEnabled else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		_ = try await sendArticleStatus(account: account, showProgress: false)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func refreshArticleStatus() async throws {
		guard let account, isCloudKitEnabled else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			let op = CloudKitReceiveStatusOperation(articlesZone: articlesZone, accountID: account.accountID, accountDisplayName: account.nameForDisplay)
			op.completionBlock = { mainThreadOperation in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				if mainThreadOperation.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume(returning: ())
				}
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func importOPML(opmlFile: URL) async throws {
		guard let account else {
			return
		}
		guard syncProgressInfo.isComplete else {
			return
		}

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		let opmlData = try Data(contentsOf: opmlFile)
		let parserData = ParserData(url: opmlFile.absoluteString, data: opmlData)
		let opmlDocument = try OPMLParser.parseOPML(with: parserData)

		// TODO: throw appropriate error if OPML file is empty.
		guard let opmlItems = opmlDocument.children, let rootExternalID = account.externalID else {
			return
		}
		let normalizedItems = OPMLNormalizer.normalize(opmlItems)

		syncProgress.addTask()
		defer {
			syncProgress.completeTask()
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		}

		do {
			try await account.logActivity(kind: .importOPML, detail: opmlFile.lastPathComponent) {
				try await accountZone.importOPML(rootExternalID: rootExternalID, items: normalizedItems)
			}
			try? await standardRefreshAll(for: account)
		} catch {
			account.postSyncError(error, operation: "Importing OPML")
			throw error
		}
	}

	@discardableResult
	func createFeed(url urlString: String, name: String?, container: Container, validateFeed: Bool) async throws -> Feed {
		guard let account else {
			throw AccountError.invalidParameter
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) url: \(urlString)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete url: \(urlString)")
		}
		guard let url = URL(string: urlString) else {
			throw AccountError.invalidParameter
		}

		let editedName = name == nil || name!.isEmpty ? nil : name
		return try await account.logActivity(kind: .subscribeFeed, detail: urlString) {
			if account.hasFeed(withURL: url.absoluteString) {
				throw AccountError.createErrorAlreadySubscribed
			}
			return try await addDeadFeed(account: account, url: url, editedName: editedName, container: container)
		}
	}

	func renameFeed(with feed: Feed, to name: String) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		let editedName = name.isEmpty ? nil : name
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
			syncProgress.completeTask()
		}

		do {
			try await account.logActivity(kind: .renameFeed, detail: feed.url) {
				try await accountZone.renameFeed(feed, editedName: editedName)
				feed.editedName = name
			}
		} catch {
			account.postSyncError(error, operation: "Renaming feed")
			throw error
		}
	}

	func removeFeed(feed: Feed, container: Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
		}

		// Optimistic local removal — sidebar updates immediately.
		container.removeFeedFromTreeAtTopLevel(feed)

		do {
			try await account.logActivity(kind: .removeFeed, detail: feed.url) {
				try await removeFeedFromCloud(for: account, with: feed, from: container)
			}
		} catch CloudKitZoneError.corruptAccount {
			// Account is corrupt. Leave the feed removed locally to clear the bad state.
		} catch {
			container.addFeedToTreeAtTopLevel(feed)
			throw error
		}
	}

	func moveFeed(feed: Feed, sourceContainer: Container, destinationContainer: Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
			syncProgress.completeTask()
		}

		do {
			try await account.logActivity(kind: .moveFeed, detail: feed.url) {
				try await accountZone.moveFeed(feed, from: sourceContainer, to: destinationContainer)
				sourceContainer.removeFeedFromTreeAtTopLevel(feed)
				destinationContainer.addFeedToTreeAtTopLevel(feed)
			}
		} catch {
			account.postSyncError(error, operation: "Moving feed")
			throw error
		}
	}

	func addFeed(feed: Feed, container: Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
			syncProgress.completeTask()
		}

		do {
			try await account.logActivity(kind: .addFeed, detail: feed.url) {
				try await accountZone.addFeed(feed, to: container)
				container.addFeedToTreeAtTopLevel(feed)
			}
		} catch {
			account.postSyncError(error, operation: "Adding feed")
			throw error
		}
	}

	func restoreFeed(feed: Feed, container: any Container) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) feed.url: \(feed.url)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete feed.url: \(feed.url)")
		}

		// The feed was already validated when first added. Skip Feed Finder and re-create the
		// CloudKit record directly, restoring the local tree position the user expects.
		syncProgress.addTask()

		container.addFeedToTreeAtTopLevel(feed)

		do {
			try await account.logActivity(kind: .restoreFeed, detail: feed.url) {
				let externalID = try await accountZone.createFeed(url: feed.url,
																  name: feed.name,
																  editedName: feed.editedName,
																  homePageURL: feed.homePageURL,
																  container: container)
				feed.externalID = externalID
			}
			syncProgress.completeTask()
		} catch {
			syncProgress.completeTask()
			container.removeFeedFromTreeAtTopLevel(feed)
			account.postSyncError(error, operation: "Restoring feed")
			throw error
		}
	}

	func createFolder(name: String) async throws -> Folder {
		guard let account else {
			throw AccountError.invalidParameter
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) name: \(name)")
		syncProgress.addTask()
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete name: \(name)")
			syncProgress.completeTask()
		}

		do {
			return try await account.logActivity(kind: .createFolder, detail: name) {
				let externalID = try await accountZone.createFolder(name: name)
				guard let folder = account.ensureFolder(with: name) else {
					throw AccountError.invalidParameter
				}
				folder.externalID = externalID
				return folder
			}
		} catch {
			account.postSyncError(error, operation: "Creating folder")
			throw error
		}
	}

	func renameFolder(with folder: Folder, to name: String) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) new name: \(name)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete new name: \(name)")
		}
		syncProgress.addTask()
		defer { syncProgress.completeTask() }

		let oldName = folder.name ?? ""
		do {
			try await account.logActivity(kind: .renameFolder, detail: "\(oldName) → \(name)") {
				try await accountZone.renameFolder(folder, to: name)
				folder.name = name
			}
		} catch {
			account.postSyncError(error, operation: "Renaming folder")
			throw error
		}
	}

	func removeFolder(with folder: Folder) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) name: \(folder.name ?? "")")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete name: \(folder.name ?? "")")
		}

		let folderName = folder.name ?? ""
		let originalFeeds = folder.topLevelFeeds

		// Optimistic local removal — sidebar updates immediately.
		account.removeFolderFromTree(folder)

		try await account.logActivity(kind: .removeFolder, detail: folderName) {
			// Two tasks: finding the folder's feed externalIDs, removing the folder record.
			// Every path below completes exactly two.
			syncProgress.addTasks(2)

			let feedExternalIDs: [String]
			do {
				feedExternalIDs = try await accountZone.findFeedExternalIDs(for: folder)
				syncProgress.completeTask()
			} catch {
				syncProgress.completeTask()
				syncProgress.completeTask()
				folder.replaceTopLevelFeeds(originalFeeds)
				account.addFolderToTree(folder)
				account.postSyncError(error, operation: "Removing folder")
				throw error
			}

			let feeds = feedExternalIDs.compactMap { account.existingFeed(withExternalID: $0) }
			var failedFeeds: Set<Feed> = []

			await withTaskGroup(of: (Feed, Error?).self) { group in
				for feed in feeds {
					group.addTask {
						do {
							try await account.logActivity(kind: .removeFeed, detail: feed.url) {
								try await self.removeFeedFromCloud(for: account, with: feed, from: folder)
							}
							return (feed, nil)
						} catch {
							Self.logger.error("CloudKit: Remove folder, remove feed error: \(error.localizedDescription)")
							return (feed, error)
						}
					}
				}

				for await (feed, error) in group {
					if let error {
						failedFeeds.insert(feed)
						account.postSyncError(error, operation: "Removing folder")
					}
				}
			}

			guard failedFeeds.isEmpty else {
				// Best-effort restore: bring the folder back with only the feeds that failed to delete
				// from CloudKit. Successfully-removed feeds stay gone locally to match cloud state.
				syncProgress.completeTask()
				folder.replaceTopLevelFeeds(failedFeeds)
				account.addFolderToTree(folder)
				throw CloudKitAccountDelegateError.unknown
			}

			do {
				try await accountZone.removeFolder(folder)
				syncProgress.completeTask()
			} catch {
				syncProgress.completeTask()
				// All feeds were removed from CloudKit but the folder record removal failed.
				// Restore an empty folder locally so it matches the cloud and the user can retry.
				folder.replaceTopLevelFeeds([])
				account.addFolderToTree(folder)
				throw error
			}
		}
	}

	func restoreFolder(folder: Folder) async throws {
		guard let account else {
			throw AccountError.invalidParameter
		}
		guard let name = folder.name else {
			throw AccountError.invalidParameter
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) name: \(name)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete name: \(name)")
		}

		let feedsToRestore = folder.topLevelFeeds
		syncProgress.addTasks(1 + feedsToRestore.count)

		do {
			try await account.logActivity(kind: .restoreFolder, detail: name) {
				let externalID = try await accountZone.createFolder(name: name)
				syncProgress.completeTask()

				folder.externalID = externalID
				account.addFolderToTree(folder)

				await withTaskGroup(of: Error?.self) { group in
					for feed in feedsToRestore {
						folder.topLevelFeeds.remove(feed)

						group.addTask {
							do {
								try await self.restoreFeed(feed: feed, container: folder)
								await self.syncProgress.completeTask()
								return nil
							} catch {
								Self.logger.error("CloudKit: Restore folder feed error: \(error.localizedDescription)")
								await self.syncProgress.completeTask()
								return error
							}
						}
					}

					for await error in group {
						if let error {
							account.postSyncError(error, operation: "Restoring folder")
						}
					}
				}

				account.addFolderToTree(folder)
			}
		} catch {
			// Only reachable when createFolder throws, before any of the
			// 1 + feedsToRestore.count tasks completed — complete them all.
			syncProgress.completeTasks(1 + feedsToRestore.count)
			account.postSyncError(error, operation: "Restoring folder")
			throw error
		}
	}

	func markArticles(articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool) async throws {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		let changedArticleIDs = await account.updateStatusesAsync(articleIDs: articleIDs, statusKey: statusKey, flag: flag)
		let syncStatuses = Set(changedArticleIDs.map { articleID in
			SyncStatus(articleID: articleID, key: SyncStatus.Key(statusKey), flag: flag)
		})

		await syncDatabase.insertStatuses(syncStatuses)
		if !syncStatuses.isEmpty {
			lastNoChangeSyncDate = nil
			NotificationCenter.default.post(name: .AccountDidQueueArticleStatuses, object: account)
		}
		if let count = try? await syncDatabase.selectPendingCount(), count > 100 {
			// Flush in the background so marking doesn't block the caller
			// <https://github.com/Ranchero-Software/NetNewsWire/issues/5273>
			Task { try? await sendArticleStatus() }
		}

		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func accountDidInitialize() {
		guard let account else {
			return
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		syncErrorHandler = { [weak self] error, operation, fileName, functionName, lineNumber in
			Task { @MainActor [weak self] in
				guard let self, let account = self.account else { return }
				account.postSyncError(error, operation: operation, fileName: fileName, functionName: functionName, lineNumber: lineNumber)
			}
		}

		syncDatabase.resetAllSelectedForProcessing()

		guard isCloudKitEnabled else {
			return
		}

		// Created locally before any fetch, so articles arriving from iCloud in this
		// launch already have their feed.
		account.ensureReadingListFeed()

		accountZone.delegate = CloudKitAcountZoneDelegate(account: account, articlesZone: articlesZone)
		articlesZone.delegate = CloudKitArticlesZoneDelegate(account: account, database: syncDatabase, articlesZone: articlesZone, syncErrorHandler: syncErrorHandler)

		let accountID = account.accountID
		let accountDisplayName = account.nameForDisplay
		func makePageHandler(kind: ActivityKind) -> CloudKitZoneFetchPageHandler {
			let what: String
			switch kind {
			case .refreshArticleStatuses:
				what = "status and content changes"
			case .refreshFeedList:
				what = "feed list changes"
			default:
				what = "changes"
			}
			return { _, changed, deleted, _ in
				let detail = "Fetching \(what) \(ActivityLog.shared.nextTaskNumberString())"
				let message = cloudKitSyncMessage(changed: changed, deleted: deleted)
				ActivityLog.shared.logCompletedActivity(owner: .account(accountID: accountID, displayName: accountDisplayName), kind: kind, detail: detail, message: message)
			}
		}
		accountZone.fetchChangesPageHandler = makePageHandler(kind: .refreshFeedList)
		articlesZone.fetchChangesPageHandler = makePageHandler(kind: .refreshArticleStatuses)

		// Check to see if this is a new account and initialize anything we need
		if account.externalID == nil {
			Task {
				do {
					let externalID = try await accountZone.findOrCreateAccount()
					account.externalID = externalID
					do {
						try await self.ensureReadingListFeedInCloud(account: account)
					} catch {
						// Retry the whole first-launch sequence next launch.
						account.externalID = nil
						throw error
					}
					try? await self.initialRefreshAll(for: account)
				} catch {
					Self.logger.error("CloudKitAccountDelegate: \(#function, privacy: .public) error: \(error.localizedDescription)")
					if let account = self.account {
						account.postSyncError(error, operation: "Creating account")
					}
				}
			}
		}

		// Checked on every launch, not only for a new account, so a reinstall or a failed
		// first attempt still ends up with push notifications.
		subscribeToZoneChangesIfNeeded(account: account)
	}

	/// Rebuilds this device’s link to iCloud: forgets the change tokens, finds or recreates
	/// the iCloud zones and subscriptions, fetches everything, then uploads any article this
	/// device has that iCloud lacks. Articles already in iCloud are left as they are there.
	func resetSync() async throws {
		guard let account, isCloudKitEnabled else {
			return
		}
		Self.logger.info("CloudKitAccountDelegate: resetting iCloud sync")

		accountZone.resetChangeToken()
		articlesZone.resetChangeToken()
		UserDefaults.standard.removeObject(forKey: Self.didSubscribeToZonesKey)
		lastNoChangeSyncDate = nil
		iCloudAccountIsUnavailable = false

		try await account.logActivity(kind: .refreshAll, detail: "Resetting iCloud sync") {
			account.externalID = try await accountZone.findOrCreateAccount()
			try await ensureReadingListFeedInCloud(account: account)
			subscribeToZoneChangesIfNeeded(account: account)
			try await initialRefreshAll(for: account)

			var articles = Set<Article>()
			for feed in account.flattenedFeeds() {
				articles.formUnion(await account.fetchArticlesAsync(.feed(feed)))
			}
			await storeArticleChanges(new: articles, updated: nil, deleted: nil)
			_ = try await sendArticleStatus(account: account, showProgress: true)
		}
	}

	/// Queues article changes for iCloud and sends them now. Without the immediate send,
	/// a save could wait out the 30-minute quiet-period backoff before leaving the device.
	func storeAndSendArticleChanges(new: Set<Article>?, updated: Set<Article>?, deleted: Set<Article>?) async {
		await storeArticleChanges(new: new, updated: updated, deleted: deleted)
		guard let account, isCloudKitEnabled else {
			return
		}
		lastNoChangeSyncDate = nil
		NotificationCenter.default.post(name: .AccountDidQueueArticleStatuses, object: account)
		Task {
			try? await sendArticleStatus()
		}
	}

	/// Saves the reading-list feed’s iCloud record. Its record name is fixed, so saving it
	/// from several devices converges on one record.
	func ensureReadingListFeedInCloud(account: Account) async throws {
		let feed = account.ensureReadingListFeed()
		_ = try await accountZone.createFeed(url: feed.url, name: feed.name, editedName: nil, homePageURL: nil, container: account)
	}

	func accountWillBeDeleted() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		accountZone.resetChangeToken()
		articlesZone.resetChangeToken()
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func vacuumDatabases() async {
		guard let account else {
			return
		}
		await account.logActivity(kind: .vacuumDatabase, detail: AppConfig.relativeDataPath(syncDatabase.databasePath)) {
			await syncDatabase.vacuum()
		}
	}

	// MARK: - Suspend and Resume

	func suspendNetwork() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
	}

	func resume() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
	}
}

// MARK: - Refresh Progress

private extension CloudKitAccountDelegate {

	func updateProgress() {
		progressInfo = syncProgressInfo
	}

	@objc func syncProgressDidChange(_ note: Notification) {
		syncProgressInfo = syncProgress.progressInfo
	}
}

// MARK: - Activity Log helper

private extension CloudKitAccountDelegate {

	static let didSubscribeToZonesKey = "cloudkit.didSubscribeToZones"

	/// Subscribes both zones to change pushes, once per install. Saving a subscription that
	/// already exists succeeds, so this is safe to repeat; the flag only avoids a request per
	/// launch. Failures are logged and retried on the next launch.
	func subscribeToZoneChangesIfNeeded(account: Account) {
		guard !UserDefaults.standard.bool(forKey: Self.didSubscribeToZonesKey) else {
			return
		}
		Task { [weak self] in
			guard let self else {
				return
			}
			let accountZoneSubscribed = await subscribeToZoneChangesWithActivity(account: account, zone: accountZone)
			let articlesZoneSubscribed = await subscribeToZoneChangesWithActivity(account: account, zone: articlesZone)
			if accountZoneSubscribed && articlesZoneSubscribed {
				UserDefaults.standard.set(true, forKey: Self.didSubscribeToZonesKey)
			}
		}
	}

	/// Wraps a zone subscription in an activity so silent failures (offline, account issues)
	/// become visible. Without a subscription there are no remote pushes.
	func subscribeToZoneChangesWithActivity(account: Account, zone: any CloudKitZone) async -> Bool {
		let zoneName = zone.zoneID.zoneName
		do {
			try await account.logActivity(kind: .subscribeToCloudKitZone, detail: zoneName) {
				try await zone.subscribeToZoneChanges()
			}
			return true
		} catch {
			Self.logger.error("CloudKitAccountDelegate: subscribeToZoneChanges \(zoneName, privacy: .public) error: \(error.localizedDescription)")
			account.postSyncError(error, operation: "Subscribing to zone changes")
			return false
		}
	}
}

// MARK: - Private

private extension CloudKitAccountDelegate {

	func initialRefreshAll(for account: Account) async throws {
		try await performRefreshAll(for: account, sendArticleStatus: false)
	}

	func standardRefreshAll(for account: Account) async throws {
		try await performRefreshAll(for: account, sendArticleStatus: true)
	}

	/// Nil when the iCloud account is available (or the status check itself failed).
	/// Otherwise an error whose message describes the unavailable state.
	private func iCloudAccountUnavailableError() async -> Error? {
		guard let status = try? await container.accountStatus() else {
			return nil
		}
		switch status {
		case .available:
			return nil
		case .temporarilyUnavailable:
			return CloudKitError(CKError(.accountTemporarilyUnavailable))
		default:
			return CloudKitError(CKError(.notAuthenticated))
		}
	}

	func performRefreshAll(for account: Account, sendArticleStatus: Bool) async throws {
		lastNoChangeSyncDate = nil
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) sendArticleStatus: \(sendArticleStatus ? "true" : "false")")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		}

		syncProgress.addTasks(2)

		let activityLog = ActivityLog.shared
		let owner = account.activityOwner

		// Overall .refreshAll activity for this account, wrapping every stage
		// below. Individual activities (fetchChangesInZone, receive/send operations)
		// log their own entries, while this one provides the account-is-refreshing
		// status at the account level.
		let refreshActivityID = activityLog.createActivity(owner: owner, kind: .refreshAll)
		activityLog.didStart(id: refreshActivityID)
		var refreshFinishedSuccessfully = false
		var iCloudError: Error?
		defer {
			if refreshFinishedSuccessfully {
				activityLog.didComplete(id: refreshActivityID, message: nil)
			} else {
				let error = iCloudError ?? NSError(domain: "CloudKitAccountDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Refresh interrupted"])
				activityLog.didFail(id: refreshActivityID, error: error)
			}
		}

		let fetchChangesDetail = "Fetching account zone changes \(activityLog.nextTaskNumberString())"

		// When iCloud fails, note the error; syncing catches up on a later refresh.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4115>
		do {
			try await activityLog.logActivity(owner: owner, kind: .refreshFeedList, detail: fetchChangesDetail) {
				try await accountZone.fetchChangesInZone()
			}
		} catch {
			if case CloudKitZoneError.userDeletedZone = error {
				// The app’s iCloud data was deleted (for instance from iCloud settings). Keep
				// everything on this device; Reset iCloud Sync uploads it again if wanted.
				accountZone.resetChangeToken()
				articlesZone.resetChangeToken()
				account.externalID = nil
				UserDefaults.standard.removeObject(forKey: Self.didSubscribeToZonesKey)
			}
			account.postSyncError(error, operation: "Fetching zone changes")
			iCloudError = error
		}
		syncProgress.completeTask()

		// Skip the remaining iCloud stages when one has already failed — they’d fail the same way.
		if iCloudError == nil {
			do {
				try await refreshArticleStatus()
			} catch {
				account.postSyncError(error, operation: "Refreshing article status")
				iCloudError = error
			}
		}
		syncProgress.completeTask()

		if sendArticleStatus && iCloudError == nil {
			do {
				_ = try await self.sendArticleStatus(account: account, showProgress: true)
			} catch {
				account.postSyncError(error, operation: "Sending article status")
				iCloudError = error
			}
		}

		syncProgress.reset()

		if let iCloudError {
			throw iCloudError
		}

		account.lastRefreshCompletedDate = Date()
		refreshFinishedSuccessfully = true
	}

	func addDeadFeed(account: Account, url: URL, editedName: String?, container: Container) async throws -> Feed {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		syncProgress.addTask()
		let feed = account.createFeed(with: editedName, url: url.absoluteString, feedID: url.absoluteString, homePageURL: nil)
		container.addFeedToTreeAtTopLevel(feed)

		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
			syncProgress.completeTask()
		}

		do {
			let externalID = try await accountZone.createFeed(url: url.absoluteString,
															  name: editedName,
															  editedName: nil,
															  homePageURL: nil,
															  container: container)
			feed.externalID = externalID
			return feed
		} catch {
			container.removeFeedFromTreeAtTopLevel(feed)
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) error: \(error.localizedDescription)")
			throw error
		}
	}

	func storeArticleChanges(new: Set<Article>?, updated: Set<Article>?, deleted: Set<Article>?) async {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		await withTaskGroup(of: Void.self) { group in
			// Every new article is uploaded with its content, even one that is already read.
			group.addTask {
				await self.insertSyncStatuses(articles: new, statusKey: .new, flag: true)
			}

			// Changed content (an extracted body arriving after the first upload, a re-save)
			// is sent as a modification; `.new` would be ignored for records that already exist.
			group.addTask {
				await self.insertSyncStatuses(articles: updated, statusKey: .content, flag: true)
			}

			group.addTask {
				await self.insertSyncStatuses(articles: deleted, statusKey: .deleted, flag: true)
			}
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	func insertSyncStatuses(articles: Set<Article>?, statusKey: SyncStatus.Key, flag: Bool) async {
		guard let articles = articles, !articles.isEmpty else {
			return
		}
		let syncStatuses = Set(articles.map { article in
			SyncStatus(articleID: article.articleID, key: statusKey, flag: flag)
		})
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		await syncDatabase.insertStatuses(syncStatuses)
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
	}

	/// Returns the number of statuses successfully sent, and whether any failed to send.
	func sendArticleStatus(account: Account, showProgress: Bool) async throws -> (sentCount: Int, didFail: Bool) {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(sentCount: Int, didFail: Bool), Error>) in
			let op = CloudKitSendStatusOperation(account: account,
												 articlesZone: articlesZone,
												 database: syncDatabase,
												 syncErrorHandler: syncErrorHandler)
			op.completionBlock = { mainThreadOperation in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				if mainThreadOperation.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume(returning: (op.sentCount, op.didFail))
				}
			}
			mainThreadOperationQueue.add(op)
		}
	}

	func removeFeedFromCloud(for account: Account, with feed: Feed, from container: Container) async throws {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
		defer {
			Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
		}

		syncProgress.addTasks(2)

		do {
			_ = try await accountZone.removeFeed(feed, from: container)
			syncProgress.completeTask()
		} catch {
			syncProgress.completeTask()
			syncProgress.completeTask()
			account.postSyncError(error, operation: "Removing feed")
			throw error
		}

		guard let feedExternalID = feed.externalID else {
			syncProgress.completeTask()
			return
		}

		do {
			try await articlesZone.deleteArticles(feedExternalID, owner: account.activityOwner)
			feed.dropConditionalGetInfo()
			syncProgress.completeTask()
		} catch {
			syncProgress.completeTask()
			account.postSyncError(error, operation: "Removing feed articles")
			throw error
		}
	}

}
