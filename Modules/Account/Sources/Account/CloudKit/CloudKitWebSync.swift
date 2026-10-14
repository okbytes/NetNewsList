//
//  CloudKitWebSync.swift
//  Account
//
//  Which way this copy of the app reaches iCloud, and the web sign-in when it’s over the web.
//  The usual way is the CloudKit framework, through the iCloud account macOS or iOS is signed
//  in to. A Mac whose macOS can’t be signed in to the user’s iCloud (a managed work Mac) uses
//  CloudKit Web Services instead, with an Apple ID sign-in that belongs to the app alone.
//  The work build sets it (Info.plist `NetNewsListICloudTransport` = `web`); any build can be
//  launched with `-NetNewsListICloudTransport web` to try it.
//  See Technotes/NetNewsList/ReadingList.md, “iCloud on the web”.
//

import Foundation
import os
import Security
import CloudKitSync

public enum CloudKitWebSyncError: LocalizedError, Sendable {
	/// The sign-in is for another Apple Account than the one this Mac used before. It isn’t used
	/// unless the user says so (`CloudKitWebSync.adopt`).
	case differentAccount(CloudKitWebSignIn)

	public var errorDescription: String? {
		NSLocalizedString("This is a different Apple Account from the one this Mac signed in with before.", comment: "iCloud sign-in error")
	}
}

@MainActor public final class CloudKitWebSync {

	public static let shared = CloudKitWebSync()

	nonisolated private static let logger = cloudKitLogger
	nonisolated private static let transportKey = "NetNewsListICloudTransport"
	nonisolated private static let apiTokenKey = "CloudKitWebAPIToken"
	/// The account of the last sign-in, so a sign-in to another one by mistake isn’t used silently.
	nonisolated private static let userRecordNameKey = "CloudKitWebUserRecordName"

	/// Whether this copy of the app reaches iCloud over the web. A launch argument
	/// (`-NetNewsListICloudTransport web`) overrides Info.plist.
	nonisolated public static var isEnabled: Bool {
		let transport = UserDefaults.standard.string(forKey: transportKey) ?? Bundle.main.object(forInfoDictionaryKey: transportKey) as? String
		return transport == "web"
	}

	/// The web database client. Nil until an API token is configured, in the build or by the user.
	public private(set) var service: CloudKitWebService?

	/// Whether a sign-in is stored. iCloud can still have ended it; the next sync finds out and
	/// posts `CloudKitWebSignInDidChange`. Read from the token store, which the service updates
	/// before it posts, so every observer of that notification sees the new state.
	public var isSignedIn: Bool {
		tokenStore.loadWebAuthToken() != nil
	}

	private let tokenStore = KeychainWebAuthTokenStore()

	private init() {
		service = makeService()
	}

	/// Whether the build carries no API token and none was entered, so the sign-in has to ask for one.
	public var needsAPIToken: Bool {
		service == nil
	}

	/// Whether the API token in use was entered by the user (the build carries none), so it can be changed.
	public var isAPITokenEnteredByUser: Bool {
		buildAPIToken() == nil && UserDefaults.standard.string(forKey: Self.apiTokenKey) != nil
	}

	/// Stores an API token entered by the user (the build had none) and starts over with it.
	public func setAPIToken(_ apiToken: String) {
		let trimmed = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
		UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.apiTokenKey)
		service = makeService()
	}

	/// Apple’s sign-in page.
	public func signInURL() async throws -> URL {
		guard let service else {
			throw CloudKitWebServiceError.notConfigured
		}
		return try await service.signInURL()
	}

	/// The sign-in token in an address Apple’s sign-in page sent the browser to, if it has one.
	/// The page sends it twice, as `ckWebAuthToken` and `ckSession`.
	nonisolated public static func webAuthToken(inCallbackURL url: URL) -> String? {
		let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		for name in ["ckWebAuthToken", "ckSession"] {
			if let token = queryItems.first(where: { $0.name == name })?.value, !token.isEmpty {
				return token
			}
		}
		return nil
	}

	/// Finishes a sign-in with the token from the sign-in page’s callback, then syncs. Throws
	/// `CloudKitWebSyncError.differentAccount` for another Apple Account than last time:
	/// syncing with it would send this Mac’s changes to that account’s iCloud.
	public func completeSignIn(webAuthToken: String) async throws {
		guard let service else {
			throw CloudKitWebServiceError.notConfigured
		}
		let signIn = try await service.verifySignIn(webAuthToken: webAuthToken)
		if let previousUser = UserDefaults.standard.string(forKey: Self.userRecordNameKey), previousUser != signIn.userRecordName {
			Self.logger.info("CloudKitWebSync: the sign-in is for a different Apple Account than before")
			throw CloudKitWebSyncError.differentAccount(signIn)
		}
		await adopt(signIn)
	}

	/// Uses a verified sign-in, and remembers its account.
	public func adopt(_ signIn: CloudKitWebSignIn) async {
		UserDefaults.standard.set(signIn.userRecordName, forKey: Self.userRecordNameKey)
		await service?.adoptSignIn(signIn)
		Self.logger.info("CloudKitWebSync: signed in to iCloud on the web")
	}

	/// Forgets the sign-in. The articles on this Mac stay; syncing stops until the next sign-in.
	public func signOut() async {
		await service?.signOut()
	}
}

private extension CloudKitWebSync {

	func makeService() -> CloudKitWebService? {
		guard let containerIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String,
			  let apiToken = configuredAPIToken() else {
			return nil
		}
		var environment = Bundle.main.object(forInfoDictionaryKey: "CloudKitEnvironment") as? String ?? ""
		if environment.isEmpty {
			environment = "development"
		}
		let configuration = CloudKitWebConfiguration(containerIdentifier: containerIdentifier, environment: environment, apiToken: apiToken)
		return CloudKitWebService(configuration: configuration, tokenStore: tokenStore)
	}

	func buildAPIToken() -> String? {
		guard let token = Bundle.main.object(forInfoDictionaryKey: "CloudKitAPIToken") as? String, !token.isEmpty else {
			return nil
		}
		return token
	}

	func configuredAPIToken() -> String? {
		if let token = buildAPIToken() {
			return token
		}
		if let token = UserDefaults.standard.string(forKey: Self.apiTokenKey), !token.isEmpty {
			return token
		}
		return nil
	}
}

/// The web auth token in the login keychain, with a copy in memory so each request doesn’t
/// read the keychain. The token changes with every request.
final class KeychainWebAuthTokenStore: CloudKitWebAuthTokenStore, @unchecked Sendable {

	private static let logger = cloudKitLogger
	private let lock = NSLock()
	private var cachedToken: String?
	private var didLoad = false
	private let service = (Bundle.main.bundleIdentifier ?? "NetNewsList") + ".CloudKitWebAuthToken"
	private let account = "webAuthToken"

	func loadWebAuthToken() -> String? {
		lock.lock()
		defer {
			lock.unlock()
		}
		if !didLoad {
			cachedToken = readKeychain()
			didLoad = true
		}
		return cachedToken
	}

	func saveWebAuthToken(_ token: String?) {
		lock.lock()
		defer {
			lock.unlock()
		}
		cachedToken = token
		didLoad = true
		writeKeychain(token)
	}

	private var baseQuery: [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: account]
	}

	private func readKeychain() -> String? {
		var query = baseQuery
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else {
			if status != errSecItemNotFound {
				Self.logger.error("KeychainWebAuthTokenStore: couldn’t read the sign-in: \(status, privacy: .public)")
			}
			return nil
		}
		return String(data: data, encoding: .utf8)
	}

	private func writeKeychain(_ token: String?) {
		guard let token else {
			let status = SecItemDelete(baseQuery as CFDictionary)
			if status != errSecSuccess && status != errSecItemNotFound {
				Self.logger.error("KeychainWebAuthTokenStore: couldn’t delete the sign-in: \(status, privacy: .public)")
			}
			return
		}
		let data = Data(token.utf8)
		let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecItemNotFound {
			var item = baseQuery
			item[kSecValueData as String] = data
			let addStatus = SecItemAdd(item as CFDictionary, nil)
			if addStatus != errSecSuccess {
				Self.logger.error("KeychainWebAuthTokenStore: couldn’t store the sign-in: \(addStatus, privacy: .public)")
			}
		} else if status != errSecSuccess {
			Self.logger.error("KeychainWebAuthTokenStore: couldn’t update the sign-in: \(status, privacy: .public)")
		}
	}
}
