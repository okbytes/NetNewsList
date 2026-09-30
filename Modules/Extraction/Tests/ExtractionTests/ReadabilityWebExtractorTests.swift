//
//  ReadabilityWebExtractorTests.swift
//  ExtractionTests
//

import Foundation
import Testing
@testable import Extraction

@Suite(.serialized) @MainActor struct ReadabilityWebExtractorTests {

	private let extractor = ReadabilityWebExtractor()

	private func extract(_ fixture: String, url: String) async throws -> ExtractedPage {
		let fileURL = try #require(Bundle.module.url(forResource: fixture, withExtension: "html", subdirectory: "Fixtures"))
		let html = try String(contentsOf: fileURL, encoding: .utf8)
		let pageURL = try #require(URL(string: url))
		return try await extractor.extract(html: html, url: pageURL)
	}

	@Test func newsArticle() async throws {
		let page = try await extract("news-article", url: "https://news.example.com/2026/09/water")
		let content = try #require(page.contentHTML)
		#expect(page.hasReadableContent)
		#expect(page.title?.contains("Towns Pool Money for Water Repairs") == true)
		#expect(page.byline?.contains("Dana Rivera") == true)
		#expect(page.siteName == "Example News")
		#expect(page.publishedTime == "2026-09-14T08:30:00Z")
		#expect(page.leadImageURL == "https://news.example.com/images/water-lead.jpg")
		#expect(content.contains("regional fund"))
		#expect(content.contains("https://news.example.com/topics/water"))
		#expect(!content.contains("Most read"))
		#expect(!content.contains("All rights reserved"))
	}

	@Test func lazyImagesKeepTheirRealSource() async throws {
		let page = try await extract("blog-lazy-images", url: "https://blog.example.org/wheel")
		let content = try #require(page.contentHTML)
		#expect(page.hasReadableContent)
		#expect(content.contains("https://cdn.example.org/wheel-1.jpg"))
	}

	@Test func codeBlocksSurvive() async throws {
		let page = try await extract("docs-code", url: "https://docs.example.com/cache")
		let content = try #require(page.contentHTML)
		#expect(content.contains("<pre>"))
		#expect(content.contains("maxSize = 2048"))
	}

	@Test func pageScriptsNeverRunAndActiveContentIsRemoved() async throws {
		let page = try await extract("xss", url: "https://example.com/post")
		let content = try #require(page.contentHTML)
		#expect(page.title == "Harmless Looking Post")
		for forbidden in ["onerror", "onload", "<script", "javascript:", "<iframe", "<form", "<input", "style=", "data-pwned"] {
			#expect(!content.contains(forbidden), "found \(forbidden)")
		}
		#expect(content.contains("https://example.com/safe"))
		#expect(content.contains("Styled paragraph"))
	}

	@Test func relativeURLsBecomeAbsolute() async throws {
		let page = try await extract("relative-base", url: "https://example.com/blog/part-one.html")
		let content = try #require(page.contentHTML)
		#expect(content.contains("https://example.com/blog/part-two.html"))
		#expect(content.contains("https://example.com/archive/"))
		#expect(content.contains("https://cdn.example.com/file.pdf"))
		#expect(content.contains("https://example.com/blog/images/diagram.png"))
	}

	@Test func scriptOnlyPageHasNoReadableContent() async throws {
		let page = try await extract("spa-shell", url: "https://app.example.com/")
		#expect(!page.hasReadableContent)
	}

	@Test func consentBannerDoesNotHideTheArticle() async throws {
		let page = try await extract("consent-wall", url: "https://trains.example.eu/night")
		let content = try #require(page.contentHTML)
		#expect(page.hasReadableContent)
		#expect(content.contains("Sleeper services"))
	}

	@Test func tinyPageIsNotReadable() async throws {
		let page = try await extract("short-post", url: "https://example.com/note")
		#expect(!page.hasReadableContent)
	}

	@Test func nonLatinTextIsPreserved() async throws {
		let page = try await extract("multilingual", url: "https://example.jp/kyoto")
		let content = try #require(page.contentHTML)
		#expect(page.hasReadableContent)
		#expect(content.contains("紅葉"))
		#expect(content.contains("🍁"))
		#expect(page.language == "ja")
	}

	@Test func tablesListsAndQuotesSurvive() async throws {
		let page = try await extract("tables-lists", url: "https://gear.example.com/tents")
		let content = try #require(page.contentHTML)
		#expect(content.contains("<table"))
		#expect(content.contains("<blockquote"))
		#expect(content.contains("Hollow 1"))
	}

	@Test func veryLongPage() async throws {
		let paragraph = "<p>" + String(repeating: "A sentence long enough to count as article text, repeated many times. ", count: 20) + "</p>\n"
		let html = "<html><head><title>Very Long</title></head><body><article><h1>Very Long</h1>" + String(repeating: paragraph, count: 1_500) + "</article></body></html>"
		let page = try await extractor.extract(html: html, url: try #require(URL(string: "https://example.com/long")))
		let content = try #require(page.contentHTML)
		#expect(content.count > 1_000_000)
	}

	@Test func extractionsRunOneAfterAnother() async throws {
		let first = try await extract("news-article", url: "https://news.example.com/a")
		let second = try await extract("docs-code", url: "https://docs.example.com/b")
		#expect(first.hasReadableContent)
		#expect(second.contentHTML?.contains("maxSize") == true)
	}
}
