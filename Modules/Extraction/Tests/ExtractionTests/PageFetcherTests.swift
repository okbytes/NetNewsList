//
//  PageFetcherTests.swift
//  ExtractionTests
//

import Foundation
import os
import Testing
@testable import Extraction

@Suite(.serialized) struct PageFetcherTests {

	private let fetcher = PageFetcher { configuration in
		configuration.protocolClasses = [StubURLProtocol.self]
	}

	@Test func returnsHTMLAndFinalURL() async throws {
		let finalURL = try #require(URL(string: "https://example.com/final"))
		StubURLProtocol.stub("https://example.com/start", StubURLProtocol.Response(url: finalURL, contentType: "text/html; charset=utf-8", body: Data("<p>héllo</p>".utf8)))
		let page = try await fetcher.fetch(try #require(URL(string: "https://example.com/start")), userAgent: "TestAgent")
		#expect(page.html == "<p>héllo</p>")
		#expect(page.url == finalURL)
		#expect(StubURLProtocol.lastUserAgent == "TestAgent")
	}

	@Test func httpErrorsThrow() async throws {
		StubURLProtocol.stub("https://example.com/missing", StubURLProtocol.Response(status: 404, contentType: "text/html", body: Data("Not found".utf8)))
		await #expect(throws: ExtractionError.httpStatus(404)) {
			_ = try await fetcher.fetch(try #require(URL(string: "https://example.com/missing")), userAgent: nil)
		}
	}

	@Test func nonHTMLThrows() async throws {
		StubURLProtocol.stub("https://example.com/file.pdf", StubURLProtocol.Response(contentType: "application/pdf", body: Data("%PDF".utf8)))
		await #expect(throws: ExtractionError.notHTML("application/pdf")) {
			_ = try await fetcher.fetch(try #require(URL(string: "https://example.com/file.pdf")), userAgent: nil)
		}
	}

	@Test func oversizedPageThrows() async throws {
		StubURLProtocol.stub("https://example.com/huge", StubURLProtocol.Response(contentType: "text/html", body: Data(count: PageFetcher.maximumBytes + 1)))
		await #expect(throws: ExtractionError.tooLarge) {
			_ = try await fetcher.fetch(try #require(URL(string: "https://example.com/huge")), userAgent: nil)
		}
	}

	@Test func nonWebURLThrows() async throws {
		await #expect(throws: ExtractionError.unsupportedURL) {
			_ = try await fetcher.fetch(try #require(URL(string: "ftp://example.com/file")), userAgent: nil)
		}
	}

	@Test func decodesTheHTTPCharset() async throws {
		let body = try #require("<p>café</p>".data(using: .isoLatin1))
		StubURLProtocol.stub("https://example.com/latin1", StubURLProtocol.Response(contentType: "text/html; charset=iso-8859-1", body: body))
		let page = try await fetcher.fetch(try #require(URL(string: "https://example.com/latin1")), userAgent: nil)
		#expect(page.html == "<p>café</p>")
	}

	@Test func decodesTheMetaCharset() async throws {
		let html = "<html><head><meta charset=\"windows-1252\"></head><body>“quoted” café</body></html>"
		let body = try #require(html.data(using: .windowsCP1252))
		StubURLProtocol.stub("https://example.com/cp1252", StubURLProtocol.Response(contentType: "text/html", body: body))
		let page = try await fetcher.fetch(try #require(URL(string: "https://example.com/cp1252")), userAgent: nil)
		#expect(page.html == html)
	}

	@Test func sniffsHTTPEquivCharset() {
		let data = Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=Shift_JIS\">".utf8)
		#expect(PageFetcher.sniffedCharset(in: data) == "shift_jis")
	}
}

final class StubURLProtocol: URLProtocol {

	struct Response: Sendable {
		var url: URL?
		var status = 200
		var contentType: String
		var body: Data
	}

	private struct State {
		var responses = [String: Response]()
		var lastUserAgent: String?
	}

	private static let state = OSAllocatedUnfairLock(initialState: State())

	static func stub(_ url: String, _ response: Response) {
		state.withLock { $0.responses[url] = response }
	}

	static var lastUserAgent: String? {
		state.withLock { $0.lastUserAgent }
	}

	override static func canInit(with request: URLRequest) -> Bool {
		true
	}

	override static func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		guard let requestURL = request.url else {
			return
		}
		let userAgent = request.value(forHTTPHeaderField: "User-Agent")
		let stubbed = Self.state.withLock { state in
			state.lastUserAgent = userAgent
			return state.responses[requestURL.absoluteString]
		}
		guard let stubbed else {
			client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
			return
		}
		let headers = ["Content-Type": stubbed.contentType, "Content-Length": String(stubbed.body.count)]
		guard let response = HTTPURLResponse(url: stubbed.url ?? requestURL, statusCode: stubbed.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: stubbed.body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {
	}
}
