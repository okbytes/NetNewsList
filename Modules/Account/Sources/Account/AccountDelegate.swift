//
//  AccountDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/16/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSWeb
import Articles

@MainActor protocol AccountDelegate: ProgressInfoReporter {

	/// The account this delegate belongs to. Set by the account during its init,
	/// before `accountDidInitialize()` is called. Held weakly to avoid a retain
	/// cycle (the account owns its delegate strongly).
	var account: Account? { get set }

	var behaviors: AccountBehaviors { get }

	var accountSettings: AccountSettings? { get set }

	func receiveRemoteNotification(userInfo: [AnyHashable: Any]) async

	func refreshAll() async throws
	/// Returns `true` if any meaningful work was done (statuses sent or local
	/// statuses changed); `false` if the round was a no-op.
	func syncArticleStatus() async throws -> Bool
	func sendArticleStatus() async throws
	func refreshArticleStatus() async throws

	func markArticles(articleIDs: Set<String>, statusKey: ArticleStatus.Key, flag: Bool) async throws

	// Called at the end of account’s init method.
	func accountDidInitialize()

	func accountWillBeDeleted()

	func vacuumDatabases() async

	/// Suspend all network activity
	func suspendNetwork()

	/// Resume network activity after a previous `suspendNetwork()`.
	func resume()
}
