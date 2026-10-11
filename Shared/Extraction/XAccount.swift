//
//  XAccount.swift
//  NetNewsList
//
//  The user's X sign-in, kept on this device in a website data store of its own. The
//  extractor loads X pages with this store, so X shows them as it would to the user,
//  and the sign-in screen shows X's own sign-in page in it. Nothing here is synced:
//  each device signs in separately, and signing out deletes the store's data.
//

import Foundation
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

	let websiteDataStore: WKWebsiteDataStore

	/// Whether X’s session cookie is in the store. Updated as cookies change.
	private(set) var isSignedIn = false

	override private init() {
		websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreIdentifier)
		super.init()
		websiteDataStore.httpCookieStore.add(self)
		Task {
			await updateSignInState()
		}
	}

	func signOut() async {
		await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
		await updateSignInState()
	}

	func updateSignInState() async {
		let cookies = await websiteDataStore.httpCookieStore.allCookies()
		let isSignedIn = cookies.contains { cookie in
			cookie.name == "auth_token" && (cookie.domain == "x.com" || cookie.domain.hasSuffix(".x.com"))
		}
		guard isSignedIn != self.isSignedIn else {
			return
		}
		self.isSignedIn = isSignedIn
		NotificationCenter.default.post(name: .XAccountSignInStateDidChange, object: self)
	}
}

extension XAccount: WKHTTPCookieStoreObserver {

	nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
		Task { @MainActor in
			await self.updateSignInState()
		}
	}
}
