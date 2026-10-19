import XCTest
import Foundation
@testable import CloudKitSync

/// The web auth token handling of `CloudKitWebService` against canned answers: every answer
/// replaces the token, and a refusal of the token ends the sign-in only when a second try
/// (the token the refusal carried, the token before the refused one, or the same one again) fails too.
final class CloudKitWebServiceTokenTests: XCTestCase {

	private var store: MemoryTokenStore!
	private var service: CloudKitWebService!

	override func setUp() {
		super.setUp()
		StubURLProtocol.reset()
		store = MemoryTokenStore()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubURLProtocol.self]
		let session = URLSession(configuration: configuration)
		service = CloudKitWebService(configuration: CloudKitWebConfiguration(containerIdentifier: "iCloud.test", environment: "development", apiToken: "api"), tokenStore: store, session: session)
	}

	func testEachAnswerReplacesTheTokenAndKeepsThePreviousOne() async throws {
		await service.adoptSignIn(CloudKitWebSignIn(userRecordName: "u", webAuthToken: "t1"))
		StubURLProtocol.answers = [.ok(token: "t2"), .ok(token: "t3")]

		_ = try await service.send(path: "users/current", body: nil)
		XCTAssertEqual(store.loadWebAuthToken(), "t2")
		XCTAssertEqual(store.loadPreviousWebAuthToken(), "t1")

		_ = try await service.send(path: "users/current", body: nil)
		XCTAssertEqual(store.loadWebAuthToken(), "t3")
		XCTAssertEqual(store.loadPreviousWebAuthToken(), "t2")
		XCTAssertEqual(StubURLProtocol.tokensSent, ["t1", "t2"])
	}

	func testRefusedTokenIsRetriedWithThePreviousOneAndTheSignInStays() async throws {
		await service.adoptSignIn(CloudKitWebSignIn(userRecordName: "u", webAuthToken: "t1"))
		StubURLProtocol.answers = [.ok(token: "t2")]
		_ = try await service.send(path: "users/current", body: nil)

		// The answer that carried t3 was lost: iCloud refuses t2, and t1 is tried.
		StubURLProtocol.answers = [.authenticationRequired(token: nil), .ok(token: "t4")]
		_ = try await service.send(path: "users/current", body: nil)

		XCTAssertEqual(StubURLProtocol.tokensSent, ["t1", "t2", "t1"])
		XCTAssertEqual(store.loadWebAuthToken(), "t4")
		XCTAssertEqual(store.loadPreviousWebAuthToken(), "t1", "the fallback token, once accepted, is the one before the current token")
		let isSignedIn = await service.isSignedIn
		XCTAssertTrue(isSignedIn)
	}

	func testRefusalThatCarriesATokenIsRetriedWithIt() async throws {
		await service.adoptSignIn(CloudKitWebSignIn(userRecordName: "u", webAuthToken: "t1"))
		StubURLProtocol.answers = [.authenticationRequired(token: "t2"), .ok(token: "t3")]

		_ = try await service.send(path: "users/current", body: nil)

		XCTAssertEqual(StubURLProtocol.tokensSent, ["t1", "t2"])
		XCTAssertEqual(store.loadWebAuthToken(), "t3")
	}

	func testSecondRefusalEndsTheSignIn() async throws {
		await service.adoptSignIn(CloudKitWebSignIn(userRecordName: "u", webAuthToken: "t1"))
		StubURLProtocol.answers = [.ok(token: "t2")]
		_ = try await service.send(path: "users/current", body: nil)
		StubURLProtocol.answers = [.authenticationRequired(token: nil), .authenticationRequired(token: nil)]

		do {
			_ = try await service.send(path: "users/current", body: nil)
			XCTFail("expected signInRequired")
		} catch CloudKitWebServiceError.signInRequired {
		}

		XCTAssertEqual(StubURLProtocol.tokensSent, ["t1", "t2", "t1"])
		XCTAssertNil(store.loadWebAuthToken())
		XCTAssertNil(store.loadPreviousWebAuthToken())
		let isSignedIn = await service.isSignedIn
		XCTAssertFalse(isSignedIn)
	}
}

private final class MemoryTokenStore: CloudKitWebAuthTokenStore, @unchecked Sendable {
	private let lock = NSLock()
	private var token: String?
	private var previous: String?

	func loadWebAuthToken() -> String? {
		lock.withLock { token }
	}

	func saveWebAuthToken(_ token: String?) {
		lock.withLock { self.token = token }
	}

	func loadPreviousWebAuthToken() -> String? {
		lock.withLock { previous }
	}

	func savePreviousWebAuthToken(_ token: String?) {
		lock.withLock { previous = token }
	}
}

private final class StubURLProtocol: URLProtocol {

	enum Answer {
		case ok(token: String)
		case authenticationRequired(token: String?)
	}

	nonisolated(unsafe) private static var queue = [Answer]()
	nonisolated(unsafe) private static var sent = [String]()
	private static let lock = NSLock()

	static var answers: [Answer] {
		get { lock.withLock { queue } }
		set { lock.withLock { queue = newValue } }
	}

	/// The `ckWebAuthToken` of each request, in order.
	static var tokensSent: [String] {
		lock.withLock { sent }
	}

	static func reset() {
		lock.withLock {
			queue = []
			sent = []
		}
	}

	override static func canInit(with request: URLRequest) -> Bool {
		true
	}

	override static func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		let token = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ckWebAuthToken" }?.value } ?? ""
		let answer: Answer? = Self.lock.withLock {
			Self.sent.append(token)
			return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
		}
		let status: Int
		var headers = [String: String]()
		let body: [String: Any]
		switch answer {
		case .ok(let newToken):
			status = 200
			headers["X-Apple-CloudKit-Web-Auth-Token"] = newToken
			body = ["userRecordName": "u"]
		case .authenticationRequired(let newToken):
			status = 421
			if let newToken {
				headers["X-Apple-CloudKit-Web-Auth-Token"] = newToken
			}
			body = ["serverErrorCode": "AUTHENTICATION_REQUIRED", "reason": "token expired"]
		case nil:
			status = 500
			body = ["serverErrorCode": "INTERNAL_ERROR", "reason": "no canned answer"]
		}
		guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers),
			  let data = try? JSONSerialization.data(withJSONObject: body) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
