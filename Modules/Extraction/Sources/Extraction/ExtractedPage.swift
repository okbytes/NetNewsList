//
//  ExtractedPage.swift
//  Extraction
//

import Foundation

/// The readable part of a web page, as Readability found it.
public struct ExtractedPage: Sendable, Equatable {

	/// The page’s address after redirects.
	public let url: URL
	public let title: String?
	public let byline: String?

	/// Sanitized HTML of the article body, or nil when no readable content was found.
	public let contentHTML: String?

	/// The number of characters of text in the body.
	public let textLength: Int
	public let excerpt: String?
	public let siteName: String?
	public let language: String?

	/// The publication date as the page states it, unparsed.
	public let publishedTime: String?
	public let leadImageURL: String?

	public init(url: URL, title: String?, byline: String?, contentHTML: String?, textLength: Int, excerpt: String?, siteName: String?, language: String?, publishedTime: String?, leadImageURL: String?) {
		self.url = url
		self.title = title
		self.byline = byline
		self.contentHTML = contentHTML
		self.textLength = textLength
		self.excerpt = excerpt
		self.siteName = siteName
		self.language = language
		self.publishedTime = publishedTime
		self.leadImageURL = leadImageURL
	}

	/// Whether the page has a body worth storing.
	public var hasReadableContent: Bool {
		guard let contentHTML, !contentHTML.isEmpty else {
			return false
		}
		return textLength >= Self.minimumTextLength
	}

	static let minimumTextLength = 100
}

public enum ExtractionError: LocalizedError, Sendable, Equatable {
	case unsupportedURL
	case httpStatus(Int)
	case notHTML(String)
	case tooLarge
	case undecodable
	case noReadableContent
	case timedOut
	case webContentFailed(String)
	case busy

	public var errorDescription: String? {
		switch self {
		case .unsupportedURL:
			return NSLocalizedString("Only web pages can be saved.", comment: "Extraction error")
		case .httpStatus(let status):
			let reason = HTTPURLResponse.localizedString(forStatusCode: status)
			return String(format: NSLocalizedString("The server answered %ld (%@).", comment: "Extraction error: HTTP status"), status, reason)
		case .notHTML(let mimeType):
			return String(format: NSLocalizedString("The page isn’t HTML (%@).", comment: "Extraction error: wrong content type"), mimeType)
		case .tooLarge:
			return NSLocalizedString("The page is too large to save.", comment: "Extraction error")
		case .undecodable:
			return NSLocalizedString("The page’s text couldn’t be read.", comment: "Extraction error")
		case .noReadableContent:
			return NSLocalizedString("No article text was found on the page.", comment: "Extraction error")
		case .timedOut:
			return NSLocalizedString("The page took too long to load.", comment: "Extraction error")
		case .webContentFailed(let message):
			return String(format: NSLocalizedString("The page couldn’t be read: %@", comment: "Extraction error: web content"), message)
		case .busy:
			return NSLocalizedString("Another page is being read.", comment: "Extraction error")
		}
	}
}
