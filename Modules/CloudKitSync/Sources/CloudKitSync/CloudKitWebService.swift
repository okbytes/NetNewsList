//
//  CloudKitWebService.swift
//  CloudKitSync
//
//  The iCloud private database over CloudKit Web Services, with an Apple ID sign-in that
//  belongs to this app alone. It lets the Mac app sync on a computer whose macOS isn’t
//  signed in to the user’s iCloud (a managed work Mac), where the CloudKit framework can’t
//  reach their data. See Technotes/NetNewsList/ReadingList.md, “iCloud on the web”.
//
//  The web auth token is good for one request: each response carries its replacement,
//  which is stored before the next request goes out. Requests are therefore sent one at a time.
//

import Foundation
import os

public struct CloudKitWebConfiguration: Sendable, Equatable {
	public let containerIdentifier: String
	/// "development" or "production". An API token works in one of them only.
	public let environment: String
	public let apiToken: String

	public init(containerIdentifier: String, environment: String, apiToken: String) {
		self.containerIdentifier = containerIdentifier
		self.environment = environment
		self.apiToken = apiToken
	}
}

/// Keeps the web auth token between launches.
public protocol CloudKitWebAuthTokenStore: Sendable {
	func loadWebAuthToken() -> String?
	func saveWebAuthToken(_ token: String?)
}

public enum CloudKitWebServiceError: LocalizedError, Sendable {
	/// No API token is configured.
	case notConfigured
	/// There is no sign-in, or it expired. `redirectURL` is Apple’s sign-in page, when iCloud sent it.
	case signInRequired(redirectURL: URL?)
	/// iCloud refused the request as a whole.
	case server(code: String, reason: String?, status: Int, retryAfter: TimeInterval?)
	/// The response wasn’t what CloudKit Web Services sends.
	case invalidResponse(status: Int)

	public var errorDescription: String? {
		switch self {
		case .notConfigured:
			return NSLocalizedString("iCloud isn’t set up in this copy of the app: it has no CloudKit API token. Choose Sign In to iCloud… in the app menu to enter one.", comment: "CloudKit web error")
		case .signInRequired:
			return NSLocalizedString("Sign in to iCloud to sync your reading list: choose Sign In to iCloud… in the app menu.", comment: "CloudKit web error")
		case .server(let code, let reason, _, _):
			if let reason, !reason.isEmpty {
				return String(format: NSLocalizedString("iCloud refused the request: %@ (%@).", comment: "CloudKit web error"), reason, code)
			}
			return String(format: NSLocalizedString("iCloud refused the request (%@).", comment: "CloudKit web error"), code)
		case .invalidResponse(let status):
			return String(format: NSLocalizedString("iCloud sent an unexpected response (HTTP %d).", comment: "CloudKit web error"), status)
		}
	}
}

public extension Notification.Name {
	/// Posted on the main thread when the web sign-in starts or ends, including when iCloud ends it.
	static let CloudKitWebSignInDidChange = Notification.Name("CloudKitWebSignInDidChange")
}

public actor CloudKitWebService {

	nonisolated private static let logger = cloudKitLogger
	private static let baseURL = "https://api.apple-cloudkit.com/database/1"
	/// The headers that carry the replacement web auth token, in the order they’re checked.
	private static let tokenHeaders = ["X-Apple-CloudKit-Web-Auth-Token", "X-Apple-CloudKit-Session"]

	public nonisolated let configuration: CloudKitWebConfiguration
	private let tokenStore: any CloudKitWebAuthTokenStore
	private let session: URLSession
	/// Assets come from and go to another host. Sharing an HTTP/2 connection with the API host
	/// can make it answer 421 (Misdirected Request), so they get a session of their own.
	private let assetSession: URLSession

	/// Set when iCloud asks to wait longer than a retry is worth: requests fail at once until then.
	private var throttledUntil: Date?
	private static let longestRetryWait: TimeInterval = 60

	private var isSending = false
	private var waitingToSend = [CheckedContinuation<Void, Never>]()

	public init(configuration: CloudKitWebConfiguration, tokenStore: any CloudKitWebAuthTokenStore, session: URLSession? = nil) {
		self.configuration = configuration
		self.tokenStore = tokenStore
		self.session = session ?? Self.makeSession()
		self.assetSession = session ?? Self.makeSession()
	}

	private static func makeSession() -> URLSession {
		let sessionConfiguration = URLSessionConfiguration.ephemeral
		sessionConfiguration.timeoutIntervalForRequest = 60
		sessionConfiguration.timeoutIntervalForResource = 600
		sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
		sessionConfiguration.httpShouldSetCookies = false
		return URLSession(configuration: sessionConfiguration)
	}

	/// Whether a web auth token is stored. It may still have expired; the next request finds out.
	public var isSignedIn: Bool {
		tokenStore.loadWebAuthToken() != nil
	}

	// MARK: - Sign-In

	/// Apple’s sign-in page. After the sign-in it sends the browser to the API token’s
	/// sign-in callback with `ckWebAuthToken` in the query.
	public func signInURL() async throws -> URL {
		do {
			_ = try await sendJSON(path: "users/current", body: nil, authenticated: false)
		} catch CloudKitWebServiceError.signInRequired(let redirectURL) {
			if let redirectURL {
				return redirectURL
			}
		}
		throw CloudKitWebServiceError.invalidResponse(status: 421)
	}

	/// Stores the token from the sign-in callback and spends it at once on `users/current`,
	/// which proves iCloud accepts it. Returns the user’s record name.
	@discardableResult
	public func completeSignIn(webAuthToken: String) async throws -> String {
		await acquireSendSlot()
		defer {
			releaseSendSlot()
		}
		storeToken(webAuthToken)
		do {
			let json = try await perform(path: "users/current", body: nil, authenticated: true)
			guard let userRecordName = json["userRecordName"] as? String else {
				throw CloudKitWebServiceError.invalidResponse(status: 200)
			}
			Self.logger.info("CloudKitWebService: signed in")
			return userRecordName
		} catch {
			storeToken(nil)
			throw error
		}
	}

	/// Forgets the sign-in on this Mac.
	public func signOut() {
		storeToken(nil)
		Self.logger.info("CloudKitWebService: signed out")
	}

	/// The signed-in user’s record name. Throws `signInRequired` when there is no valid sign-in.
	public func currentUserRecordName() async throws -> String {
		let json = try await sendJSON(path: "users/current", body: nil)
		guard let userRecordName = json["userRecordName"] as? String else {
			throw CloudKitWebServiceError.invalidResponse(status: 200)
		}
		return userRecordName
	}

	// MARK: - Requests

	/// Sends a request to the private database (`path` such as `records/modify`) and returns
	/// the response’s JSON. `body` is a JSON object, encoded; nil sends a GET.
	public func send(path: String, body: Data?) async throws -> Data {
		let json = try await sendJSON(path: path, body: body)
		return try JSONSerialization.data(withJSONObject: json)
	}

	/// Uploads an asset’s bytes to the address `assets/upload` returned, and returns the
	/// response (a JSON object whose `singleFile` goes into the record’s field).
	public func uploadAssetData(_ data: Data, to url: URL) async throws -> Data {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
		let (responseData, response) = try await assetSession.upload(for: request, from: data)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw CloudKitWebServiceError.invalidResponse(status: 0)
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw Self.serverError(status: httpResponse.statusCode, json: Self.jsonObject(responseData), response: httpResponse)
		}
		return responseData
	}

	/// Downloads an asset from the `downloadURL` a record’s asset field carries.
	public func downloadAsset(from url: URL) async throws -> Data {
		let (data, response) = try await assetSession.data(from: url)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw CloudKitWebServiceError.invalidResponse(status: 0)
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw Self.serverError(status: httpResponse.statusCode, json: Self.jsonObject(data), response: httpResponse)
		}
		return data
	}
}

private extension CloudKitWebService {

	func sendJSON(path: String, body: Data?, authenticated: Bool = true) async throws -> [String: Any] {
		await acquireSendSlot()
		defer {
			releaseSendSlot()
		}
		return try await perform(path: path, body: body, authenticated: authenticated)
	}

	/// One request. Only called while holding the send slot, so the token it uses is the latest.
	func perform(path: String, body: Data?, authenticated: Bool) async throws -> [String: Any] {
		guard !configuration.apiToken.isEmpty else {
			throw CloudKitWebServiceError.notConfigured
		}
		if let throttledUntil, throttledUntil > Date() {
			throw CloudKitWebServiceError.server(code: "THROTTLED", reason: "iCloud asked to wait", status: 429, retryAfter: throttledUntil.timeIntervalSinceNow)
		}
		var token: String?
		if authenticated {
			token = tokenStore.loadWebAuthToken()
			guard token != nil else {
				throw CloudKitWebServiceError.signInRequired(redirectURL: nil)
			}
		}

		var request = URLRequest(url: try url(path: path, webAuthToken: token))
		if let body {
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = body
		} else {
			request.httpMethod = "GET"
		}

		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw CloudKitWebServiceError.invalidResponse(status: 0)
		}

		let json = Self.jsonObject(data)
		let serverErrorCode = json?["serverErrorCode"] as? String
		// Only iCloud’s own answer ends a sign-in. A bare 421 can be HTTP/2’s Misdirected Request.
		if serverErrorCode == "AUTHENTICATION_REQUIRED" || serverErrorCode == "AUTHENTICATION_FAILED" {
			if authenticated {
				Self.logger.info("CloudKitWebService: iCloud asked for a new sign-in (\(serverErrorCode ?? "", privacy: .public))")
				storeToken(nil)
			}
			let redirectURL = (json?["redirectURL"] as? String).flatMap { URL(string: $0) }
			throw CloudKitWebServiceError.signInRequired(redirectURL: redirectURL)
		}

		if authenticated, let newToken = Self.replacementToken(in: httpResponse) {
			storeToken(newToken)
		}

		guard (200..<300).contains(httpResponse.statusCode) else {
			let error = Self.serverError(status: httpResponse.statusCode, json: json, response: httpResponse)
			if case .server(_, _, _, let retryAfter?) = error, retryAfter > Self.longestRetryWait {
				throttledUntil = Date().addingTimeInterval(retryAfter)
			}
			throw error
		}
		guard let json else {
			throw CloudKitWebServiceError.invalidResponse(status: httpResponse.statusCode)
		}
		return json
	}

	func url(path: String, webAuthToken: String?) throws -> URL {
		let container = Self.percentEncoded(configuration.containerIdentifier)
		let environment = Self.percentEncoded(configuration.environment)
		var query = "ckAPIToken=\(Self.percentEncoded(configuration.apiToken))"
		if let webAuthToken {
			query += "&ckWebAuthToken=\(Self.percentEncoded(webAuthToken))"
		}
		guard let url = URL(string: "\(Self.baseURL)/\(container)/\(environment)/private/\(path)?\(query)") else {
			throw CloudKitWebServiceError.notConfigured
		}
		return url
	}

	func storeToken(_ token: String?) {
		let wasSignedIn = tokenStore.loadWebAuthToken() != nil
		tokenStore.saveWebAuthToken(token)
		if wasSignedIn != (token != nil) {
			Task { @MainActor in
				NotificationCenter.default.post(name: .CloudKitWebSignInDidChange, object: nil)
			}
		}
	}

	func acquireSendSlot() async {
		guard isSending else {
			isSending = true
			return
		}
		await withCheckedContinuation { continuation in
			waitingToSend.append(continuation)
		}
	}

	func releaseSendSlot() {
		if waitingToSend.isEmpty {
			isSending = false
		} else {
			waitingToSend.removeFirst().resume()
		}
	}

	static func replacementToken(in response: HTTPURLResponse) -> String? {
		for header in tokenHeaders {
			if let token = response.value(forHTTPHeaderField: header), !token.isEmpty {
				return token
			}
		}
		return nil
	}

	/// Percent-encodes everything but unreserved characters: the tokens contain `+`, `/` and
	/// `=`, which a query string would otherwise read as other things.
	static func percentEncoded(_ string: String) -> String {
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
	}

	static func jsonObject(_ data: Data) -> [String: Any]? {
		guard !data.isEmpty else {
			return nil
		}
		return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}

	static func serverError(status: Int, json: [String: Any]?, response: HTTPURLResponse) -> CloudKitWebServiceError {
		let code = json?["serverErrorCode"] as? String ?? "HTTP_\(status)"
		let reason = json?["reason"] as? String
		var retryAfter = (json?["retryAfter"] as? NSNumber)?.doubleValue
		if retryAfter == nil, let header = response.value(forHTTPHeaderField: "Retry-After") {
			retryAfter = TimeInterval(header)
		}
		logger.error("CloudKitWebService: HTTP \(status, privacy: .public) \(code, privacy: .public): \(reason ?? "", privacy: .public)")
		return .server(code: code, reason: reason, status: status, retryAfter: retryAfter)
	}
}
