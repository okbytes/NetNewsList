//
//  ExtractedContentFormatter.swift
//  NetNewsList
//
//  Builds the stored body for an extracted page. The page’s own publication
//  date and site name go into the HTML, never into `datePublished`, which stays
//  nil so every list sorts by the date saved. See Technotes/NetNewsList/Plan.md, D2.
//

import Foundation
import RSCore
import Extraction

enum ExtractedContentFormatter {

	static func storedHTML(for page: ExtractedPage) -> String? {
		guard let contentHTML = page.contentHTML else {
			return nil
		}
		var details = [String]()
		if let publishedTime = page.publishedTime, let date = date(from: publishedTime) {
			let dateString = date.formatted(date: .long, time: .omitted)
			details.append(String(format: NSLocalizedString("Published %@", comment: "Saved page: publication date"), dateString))
		}
		if let siteName = page.siteName {
			details.append(siteName)
		}
		guard !details.isEmpty else {
			return contentHTML
		}
		let sourceLine = details.map(\.escapingSpecialXMLCharacters).joined(separator: " · ")
		return "<p class=\"netNewsListSource\"><small>\(sourceLine)</small></p>\n\(contentHTML)"
	}

	static func date(from string: String) -> Date? {
		let formatter = ISO8601DateFormatter()
		for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
			formatter.formatOptions = options
			if let date = formatter.date(from: string) {
				return date
			}
		}
		return nil
	}
}
