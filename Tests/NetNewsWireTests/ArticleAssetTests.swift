//
//  ArticleAssetTests.swift
//  NetNewsWireTests
//
//  Offline images: the render-time rewrite to nnlasset:// and the local store’s helpers.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing

@testable import NetNewsWire

@Suite struct ArticleImageRewriterTests {

	private let baseURL = URL(string: "https://example.com/posts/one")

	@Test func imagesPointAtTheStoreAndKeepTheirOriginal() throws {
		let html = #"<p>Hi</p><img alt="A" src="https://cdn.example.com/a.jpg?w=1&amp;h=2" srcset="https://cdn.example.com/a@2x.jpg 2x" sizes="100vw">"#
		let rewritten = ArticleImageRewriter.rewrite(html, articleID: "abc", baseURL: baseURL)
		let expectedAsset = ArticleImageRewriter.assetURL(articleID: "abc", originalURL: "https://cdn.example.com/a.jpg?w=1&h=2")
		#expect(rewritten.contains("src=\"\(expectedAsset)\""))
		#expect(rewritten.contains(#"data-nnl-src="https://cdn.example.com/a.jpg?w=1&amp;h=2""#))
		#expect(!rewritten.contains("srcset"))
		#expect(!rewritten.contains("sizes="))
		#expect(rewritten.hasPrefix("<p>Hi</p><img alt=\"A\""))
	}

	@Test func relativeImagesResolveAgainstThePage() {
		let rewritten = ArticleImageRewriter.rewrite(#"<img src='/img/b.png'>"#, articleID: "abc", baseURL: baseURL)
		#expect(rewritten.contains(ArticleImageRewriter.assetURL(articleID: "abc", originalURL: "https://example.com/img/b.png")))
	}

	@Test func dataAndNonWebImagesAreLeftAlone() {
		let html = #"<img src="data:image/png;base64,AAAA"><img src="nnwImageIcon:abc">"#
		#expect(ArticleImageRewriter.rewrite(html, articleID: "abc", baseURL: baseURL) == html)
	}

	@Test func pictureSourcesLoseTheirCandidates() {
		let html = #"<picture><source srcset="https://cdn.example.com/c.webp" type="image/webp"><img src="https://cdn.example.com/c.jpg"></picture>"#
		let rewritten = ArticleImageRewriter.rewrite(html, articleID: "abc", baseURL: baseURL)
		#expect(rewritten.contains(#"<source type="image/webp">"#))
		#expect(!rewritten.contains("c.webp"))
	}

	@Test func imageURLsAreDedupedInDocumentOrder() {
		let html = #"<img src="https://a.example/1.png"><img src="https://a.example/2.png"><img src="https://a.example/1.png"><img src="data:x">"#
		#expect(ArticleImageRewriter.imageURLs(in: html, baseURL: nil) == ["https://a.example/1.png", "https://a.example/2.png"])
	}

	@Test func assetURLsRoundTrip() throws {
		let original = "https://cdn.example.com/päth/image.jpg?x=1&y=ü#frag"
		let assetURL = try #require(URL(string: ArticleImageRewriter.assetURL(articleID: "0123abcd", originalURL: original)))
		let parsed = try #require(ArticleImageRewriter.parse(assetURL: assetURL))
		#expect(parsed.articleID == "0123abcd")
		#expect(parsed.originalURL == original)
		#expect(ArticleImageRewriter.parse(assetURL: try #require(URL(string: "https://example.com/x"))) == nil)
	}
}

@Suite struct ArticleAssetStoreTests {

	@Test func sniffsImageTypes() {
		#expect(ArticleAssetStore.mimeType(for: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
		#expect(ArticleAssetStore.mimeType(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == "image/png")
		#expect(ArticleAssetStore.mimeType(for: Data("GIF89a".utf8)) == "image/gif")
		#expect(ArticleAssetStore.mimeType(for: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == "image/webp")
		#expect(ArticleAssetStore.mimeType(for: Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == "image/svg+xml")
	}

	@Test func largeImagesAreStoredAt1600Pixels() throws {
		let large = try pngData(width: 3200, height: 1000)
		let stored = ArticleAssetStore.downsampledIfLarge(large)
		let source = try #require(CGImageSourceCreateWithData(stored as CFData, nil))
		let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
		#expect(properties[kCGImagePropertyPixelWidth] as? Int == 1600)
		#expect(properties[kCGImagePropertyPixelHeight] as? Int == 500)

		let small = try pngData(width: 800, height: 600)
		#expect(ArticleAssetStore.downsampledIfLarge(small) == small)
	}

	@Test func filesAreKeyedByArticleAndURL() {
		let store = ArticleAssetStore.shared
		let first = store.fileURL(articleID: "a1", originalURL: "https://example.com/x.png")
		#expect(first == store.fileURL(articleID: "a1", originalURL: "https://example.com/x.png"))
		#expect(first != store.fileURL(articleID: "a1", originalURL: "https://example.com/y.png"))
		#expect(first.deletingLastPathComponent().lastPathComponent == "a1")
	}

	private func pngData(width: Int, height: Int) throws -> Data {
		let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
		context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		let image = try #require(context.makeImage())
		let data = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, nil)
		#expect(CGImageDestinationFinalize(destination))
		return data as Data
	}
}
