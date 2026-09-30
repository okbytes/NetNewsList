//
//  ArticleIngressTests.swift
//  NetNewsWireTests
//
//  The ways a page reaches the app: netnewslist://add, share-extension requests
//  and bodies handed in by Shortcuts.
//

import Foundation
import Testing

@testable import NetNewsWire

@Suite struct AddArticleURLSchemeTests {

	private func request(_ string: String) throws -> SavedArticleRequest? {
		AddArticleURLScheme.request(from: try #require(URL(string: string)))
	}

	@Test func readsURLAndTitle() throws {
		let request = try #require(try request("netnewslist://add?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2&title=Hello%20World"))
		#expect(request.url == "https://example.com/a?b=1&c=2")
		#expect(request.title == "Hello World")
	}

	@Test func titleIsOptional() throws {
		let request = try #require(try request("NetNewsList://ADD/?url=https://example.com/"))
		#expect(request.url == "https://example.com/")
		#expect(request.title == nil)
	}

	@Test func emptyTitleIsNil() throws {
		let request = try #require(try request("netnewslist://add?url=https://example.com/&title=%20"))
		#expect(request.title == nil)
	}

	@Test func otherURLsAreIgnored() throws {
		#expect(try request("netnewslist://theme/add?url=https://example.com/theme.nnwtheme") == nil)
		#expect(try request("netnewslist://add") == nil)
		#expect(try request("netnewslist://add?url=") == nil)
		#expect(try request("https://example.com/add?url=https://example.com/") == nil)
	}
}

@Suite struct SavedArticleRequestTests {

	@Test func roundTripsAsAPropertyList() throws {
		let request = SavedArticleRequest(url: "https://example.com/", title: "Title", body: "<p>Body</p>", dateRequested: Date(timeIntervalSince1970: 1_800_000_000))
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		let decoded = try PropertyListDecoder().decode(SavedArticleRequest.self, from: encoder.encode(request))
		#expect(decoded == request)
	}
}

@Suite struct SuppliedBodyTests {

	@Test func htmlIsKept() {
		let html = "<p>One</p><p>Two</p>"
		#expect(ExtractedContentFormatter.storedHTML(forSuppliedBody: html) == html)
	}

	@Test func plainTextBecomesEscapedParagraphs() {
		let text = "First line & more\n\n<not a tag> second\n"
		#expect(ExtractedContentFormatter.storedHTML(forSuppliedBody: text) == "<p>First line &amp; more</p>\n<p>&lt;not a tag&gt; second</p>")
	}

	@Test func emptyBodyIsNil() {
		#expect(ExtractedContentFormatter.storedHTML(forSuppliedBody: nil) == nil)
		#expect(ExtractedContentFormatter.storedHTML(forSuppliedBody: " \n ") == nil)
	}
}
