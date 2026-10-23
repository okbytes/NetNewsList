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
import RSWeb
import SyncDatabase
import Articles
import ArticlesDatabase
import CloudKitSync

/// Parameters: (error, operation, fileName, functionName, lineNumber)
typealias CloudKitSyncErrorHandler = @Sendable (Error, String, String, String, Int) -> Void

enum CloudKitAccountDelegateError: LocalizedError, Sendable {
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

	/// Set when this copy of the app reaches iCloud over the web (`CloudKitWebSync`): the zones
	/// then use it, and the CKContainer is never made.
	private lazy var webDatabase: CloudKitWebDatabase? = CloudKitWebSync.isEnabled ? CloudKitWebDatabase(serviceProvider: { CloudKitWebSync.shared.service }) : nil

	private lazy var articlesZone = webDatabase.map { CloudKitArticlesZone(webDatabase: $0) } ?? CloudKitArticlesZone(container: container)

	private let mainThreadOperationQueue = MainThreadOperationQueue()
	private var syncErrorHandler: CloudKitSyncErrorHandler?

	private var lastNoChangeSyncDate: Date?
	/// How long a sync that found nothing new holds off the next. Pushes end it early, but over
	/// the web there are none, so the timer’s checks are what bring other devices’ changes.
	private var noChangeBackoffInterval: TimeInterval {
		CloudKitWebSync.isEnabled ? 0 : 30 * 60
	}

	/// Whether this launch has settled saved dates with iCloud, or is doing it (`settleSavedDatesIfNeeded`).
	private var didSettleSavedDates = false

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
		NotificationCenter.default.addObserver(self, selector: #selector(webSignInDidChange(_:)), name: .CloudKitWebSignInDidChange, object: nil)
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

	/// The web sign-in started or ended. A new sign-in syncs at once, finishing the first-launch
	/// setup if this Mac couldn’t do it without one.
	@objc func webSignInDidChange(_ note: Notification) {
		guard isCloudKitEnabled, CloudKitWebSync.isEnabled, CloudKitWebSync.shared.isSignedIn, let account else {
			return
		}
		iCloudAccountIsUnavailable = false
		lastNoChangeSyncDate = nil
		Self.logger.info("CloudKitAccountDelegate: signed in to iCloud on the web — syncing")
		if account.externalID == nil {
			startFirstLaunchSetup(account: account)
		} else {
			Task {
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
			let op = CloudKitRemoteNotificationOperation(articlesZone: articlesZone, accountID: account.accountID, accountDisplayName: account.nameForDisplay, userInfo: userInfo)
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
		// Signed out over the web: nothing can sync until the sign-in, which syncs at once.
		if CloudKitWebSync.isEnabled && !CloudKitWebSync.shared.isSignedIn {
			return false
		}
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")

		if let lastNoChangeSyncDate, Date().timeIntervalSince(lastNoChangeSyncDate) < noChangeBackoffInterval {
			Self.logger.debug("CloudKitAccountDelegate: Skipping sync — no changes on last check, backing off")
			return false
		}

		let sendResult = try await sendArticleStatus(account: account, showProgress: false)
		try await refreshArticleStatus()

		let didReceiveChanges = !articlesZoneHasNoChanges
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
		let op = CloudKitReceiveStatusOperation(articlesZone: articlesZone, accountID: account.accountID, accountDisplayName: account.nameForDisplay)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			op.completionBlock = { mainThreadOperation in
				Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public) did complete")
				if mainThreadOperation.isCanceled {
					continuation.resume(throwing: CloudKitAccountDelegateError.unknown)
				} else {
					continuation.resume()
				}
			}
			mainThreadOperationQueue.add(op)
		}
		// Other fetch failures are logged and tried again at the next sync; this one ends syncing.
		if let error = op.error, case CloudKitZoneError.userDeletedZone = error {
			throw error
		}
		// Every sync path fetches here: the Mac's timer sync as well as a full refresh.
		if op.didFetchChanges {
			await settleSavedDatesIfNeeded(account: account)
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

		articlesZone.delegate = CloudKitArticlesZoneDelegate(account: account, database: syncDatabase, syncErrorHandler: syncErrorHandler)

		let accountID = account.accountID
		let accountDisplayName = account.nameForDisplay
		func makePageHandler(kind: ActivityKind) -> CloudKitZoneFetchPageHandler {
			let what: String
			switch kind {
			case .refreshArticleStatuses:
				what = "status and content changes"
			default:
				what = "changes"
			}
			return { _, changed, deleted, _ in
				let detail = "Fetching \(what) \(ActivityLog.shared.nextTaskNumberString())"
				let message = cloudKitSyncMessage(changed: changed, deleted: deleted)
				ActivityLog.shared.logCompletedActivity(owner: .account(accountID: accountID, displayName: accountDisplayName), kind: kind, detail: detail, message: message)
			}
		}
		articlesZone.fetchChangesPageHandler = makePageHandler(kind: .refreshArticleStatuses)

		// Over the web, nothing reaches iCloud before the sign-in, which finishes this setup.
		let canReachICloud = !CloudKitWebSync.isEnabled || CloudKitWebSync.shared.isSignedIn

		guard canReachICloud else {
			return
		}
		if account.externalID == nil {
			startFirstLaunchSetup(account: account)
		}

		// Checked on every launch, not only for a new account, so a reinstall or a failed
		// first attempt still ends up with push notifications.
		subscribeToZoneChangesIfNeeded(account: account)
	}

	/// Set as the account’s external ID once the first launch has set up iCloud. Accounts set up
	/// before 2026-10-22 have the name of their old Account-zone record instead; either way,
	/// only whether there is one matters.
	static let accountExternalID = "reading-list"

	/// Creates the Articles zone (saving one that exists changes nothing), then fetches
	/// everything. A failure is tried again at the next launch (or web sign-in).
	func startFirstLaunchSetup(account: Account) {
		Task {
			do {
				try await articlesZone.createZoneRecord()
				account.externalID = Self.accountExternalID
				try? await self.initialRefreshAll(for: account)
			} catch {
				Self.logger.error("CloudKitAccountDelegate: \(#function, privacy: .public) error: \(error.localizedDescription)")
				if let account = self.account {
					account.postSyncError(error, operation: "Creating account")
				}
			}
		}
	}

	/// Rebuilds this device’s link to iCloud: forgets the change token, finds or recreates
	/// the Articles zone and its subscription, fetches everything, then uploads any article this
	/// device has that iCloud lacks. Articles already in iCloud are left as they are there.
	func resetSync() async throws {
		guard let account, isCloudKitEnabled else {
			return
		}
		Self.logger.info("CloudKitAccountDelegate: resetting iCloud sync")

		articlesZone.resetChangeToken()
		UserDefaults.standard.removeObject(forKey: Self.didSubscribeToZonesKey)
		lastNoChangeSyncDate = nil
		iCloudAccountIsUnavailable = false

		try await account.logActivity(kind: .refreshAll, detail: "Resetting iCloud sync") {
			try await articlesZone.createZoneRecord()
			account.externalID = Self.accountExternalID
			subscribeToZoneChangesIfNeeded(account: account)
			try await initialRefreshAll(for: account)

			var articles = Set<Article>()
			for feed in account.flattenedFeeds() {
				articles.formUnion(await account.fetchArticlesAsync(.feed(feed)))
			}
			// Re-uploads, queued with the flag off: unlike a save made here, a deletion from iCloud
			// still removes one (`CloudKitArticlesZoneDelegate.delete`). A save here still waiting
			// to go keeps its own row.
			let pendingSaves = (try? await syncDatabase.selectPendingFirstUploadArticleIDs()) ?? Set<String>()
			await insertSyncStatuses(articles: articles.filter { !pendingSaves.contains($0.articleID) }, statusKey: .new, flag: false)
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

	func accountWillBeDeleted() {
		Self.logger.debug("CloudKitAccountDelegate: \(#function, privacy: .public)")
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

	/// Subscribes the Articles zone to change pushes, once per install. Saving a subscription that
	/// already exists succeeds, so this is safe to repeat; the flag only avoids a request per
	/// launch. Failures are logged and retried on the next launch.
	func subscribeToZoneChangesIfNeeded(account: Account) {
		// Over the web there are no pushes to subscribe to. Skipping here also keeps the flag
		// meaning “subscribed through the CloudKit framework” on a Mac that has used both.
		guard webDatabase == nil else {
			return
		}
		guard !UserDefaults.standard.bool(forKey: Self.didSubscribeToZonesKey) else {
			return
		}
		Task { [weak self] in
			guard let self else {
				return
			}
			if await subscribeToZoneChangesWithActivity(account: account, zone: articlesZone) {
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
		if CloudKitWebSync.isEnabled {
			if CloudKitWebSync.shared.needsAPIToken {
				return CloudKitWebServiceError.notConfigured
			}
			return CloudKitWebSync.shared.isSignedIn ? nil : CloudKitWebServiceError.signInRequired(redirectURL: nil)
		}
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

		syncProgress.addTask()

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

		// When iCloud fails, note the error; syncing catches up on a later refresh.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4115>
		do {
			try await refreshArticleStatus()
		} catch {
			if case CloudKitZoneError.userDeletedZone = error {
				// The app’s iCloud data was deleted (for instance from iCloud settings). Keep
				// everything on this device; Reset iCloud Sync uploads it again if wanted.
				articlesZone.resetChangeToken()
				account.externalID = nil
				UserDefaults.standard.removeObject(forKey: Self.didSubscribeToZonesKey)
			}
			account.postSyncError(error, operation: "Refreshing article status")
			iCloudError = error
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

	/// Once a launch, after a fetch, so this device knows the saved dates iCloud has: offers this
	/// device’s arrival times as saved dates (`Account.savedDateProposals()`) and stores the
	/// dates iCloud settles on. A failure is tried again at the next sync.
	func settleSavedDatesIfNeeded(account: Account) async {
		guard !didSettleSavedDates else {
			return
		}
		didSettleSavedDates = true
		let proposals = await account.savedDateProposals()
		guard !proposals.isEmpty else {
			return
		}
		do {
			let settledDates = try await articlesZone.settleSavedDates(proposals)
			await account.updateSavedDates(settledDates)
		} catch {
			Self.logger.error("CloudKitAccountDelegate: couldn’t settle saved dates: \(error.localizedDescription, privacy: .public)")
			didSettleSavedDates = false
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
}
