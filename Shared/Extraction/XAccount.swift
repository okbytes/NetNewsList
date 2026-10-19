//
//  XAccount.swift
//  NetNewsList
//
//  The user's X sign-in, kept on this device in a website data store of its own. The
//  extractor loads X pages with this store, so X shows them as it would to the user,
//  and the sign-in screen shows X's own sign-in page in it. Nothing here is synced:
//  each device signs in separately, and signing out deletes the store's data.
//
//  The session cookies are also copied to the keychain, so a website data store that comes
//  back empty (WebKit reset it, or something cleaned the app's data) doesn't need a new
//  sign-in: the copy goes back into the store at launch.
//

import Foundation
import os
import Security
import WebKit

extension Notification.Name {
	static let XAccountSignInStateDidChange = Notification.Name("XAccountSignInStateDidChange")
}

@MainActor final class XAccount: NSObject {

	static let shared = XAccount()

	/// X's sign-in page.
	static let signInAddress = "https://x.com/i/flow/login"

	/// Fixed, so the sign-in screen and the extractor use the same store on every launch.
	private static let dataStoreIdentifier = UUID(uuid: (0x9F, 0xD7, 0x95, 0x83, 0xBD, 0x06, 0x44, 0x27, 0x81, 0x9C, 0xA3, 0x8E, 0xA2, 0x08, 0xE2, 0x64))
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "XAccount")
	private static let sessionCookieName = "auth_token"

	let websiteDataStore: WKWebsiteDataStore

	/// Whether X’s session cookie is in the store. Updated as cookies change.
	private(set) var isSignedIn = false

	private let cookieBackup = KeychainCookieBackup()
	private var lastBackup: Data?

	override private init() {
		websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
		super.init()
		websiteDataStore.httpCookieStore.add(self)
		Task {
			await updateSignInState()
			if !isSignedIn {
				await restoreSessionIfNeeded()
			}
			// The cookie store doesn’t always answer in full right after launch: look again.
			try? await Task.sleep(for: .seconds(5))
			await updateSignInState()
			if !isSignedIn {
				await restoreSessionIfNeeded()
			}
		}
	}

	func signOut() async {
		cookieBackup.save(nil)
		lastBackup = nil
		await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
		await updateSignInState()
	}

	func updateSignInState() async {
		let cookies = Self.xCookies(in: await websiteDataStore.httpCookieStore.allCookies())
		let isSignedIn = cookies.contains { $0.name == Self.sessionCookieName }
		if isSignedIn {
			backUp(cookies)
		}
		guard isSignedIn != self.isSignedIn else {
			return
		}
		self.isSignedIn = isSignedIn
		Self.logger.notice("XAccount: \(isSignedIn ? "signed in" : "signed out", privacy: .public)")
		NotificationCenter.default.post(name: .XAccountSignInStateDidChange, object: self)
	}
}

private extension XAccount {

	static func xCookies(in cookies: [HTTPCookie]) -> [HTTPCookie] {
		cookies.filter { $0.domain == "x.com" || $0.domain.hasSuffix(".x.com") }
	}

	/// Keeps a copy of X's cookies in the keychain whenever they change.
	func backUp(_ cookies: [HTTPCookie]) {
		guard let data = try? JSONEncoder().encode(cookies.map(StoredCookie.init)), data != lastBackup else {
			return
		}
		lastBackup = data
		cookieBackup.save(data)
	}

	/// Puts the keychain's copy of the session back into an empty store.
	func restoreSessionIfNeeded() async {
		guard let data = cookieBackup.load(), let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else {
			return
		}
		let cookies = stored.compactMap(\.cookie).filter { cookie in
			guard let expiresDate = cookie.expiresDate else {
				return true
			}
			return expiresDate > Date()
		}
		guard cookies.contains(where: { $0.name == Self.sessionCookieName }) else {
			return
		}
		Self.logger.notice("XAccount: the website data store has no X session; restoring the keychain’s copy")
		for cookie in cookies {
			await websiteDataStore.httpCookieStore.setCookie(cookie)
		}
		await updateSignInState()
	}
}

extension XAccount: WKHTTPCookieStoreObserver {

	nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
		Task { @MainActor in
			await self.updateSignInState()
		}
	}
}

/// A cookie as the keychain copy stores it.
private struct StoredCookie: Codable {
	let name: String
	let value: String
	let domain: String
	let path: String
	let expires: Date?
	let isSecure: Bool
	let isHTTPOnly: Bool

	init(_ cookie: HTTPCookie) {
		name = cookie.name
		value = cookie.value
		domain = cookie.domain
		path = cookie.path
		expires = cookie.expiresDate
		isSecure = cookie.isSecure
		isHTTPOnly = cookie.isHTTPOnly
	}

	var cookie: HTTPCookie? {
		var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
		if let expires {
			properties[.expires] = expires
		}
		if isSecure {
			properties[.secure] = "TRUE"
		}
		if isHTTPOnly {
			properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
		}
		return HTTPCookie(properties: properties)
	}
}

/// The keychain item that holds the copy of X's cookies.
private final class KeychainCookieBackup {

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "XAccount")
	private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
										kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "NetNewsList") + ".XSessionCookies",
										kSecAttrAccount as String: "cookies"]

	func load() -> Data? {
		var query = query
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess, let data = result as? Data else {
			if status != errSecItemNotFound {
				Self.logger.error("XAccount: couldn’t read the keychain’s copy of the X session: \(status, privacy: .public)")
			}
			return nil
		}
		return data
	}

	func save(_ data: Data?) {
		guard let data else {
			let status = SecItemDelete(query as CFDictionary)
			if status != errSecSuccess && status != errSecItemNotFound {
				Self.logger.error("XAccount: couldn’t delete the keychain’s copy of the X session: \(status, privacy: .public)")
			}
			return
		}
		let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if status == errSecItemNotFound {
			var item = query
			item[kSecValueData as String] = data
			let addStatus = SecItemAdd(item as CFDictionary, nil)
			if addStatus != errSecSuccess {
				Self.logger.error("XAccount: couldn’t store a copy of the X session: \(addStatus, privacy: .public)")
			}
		} else if status != errSecSuccess {
			Self.logger.error("XAccount: couldn’t update the keychain’s copy of the X session: \(status, privacy: .public)")
		}
	}
}
