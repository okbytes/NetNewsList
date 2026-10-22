//
//  ExtractedContentFormatter.swift
//  NetNewsList
//
//  Builds the stored body for an extracted page. The page’s own publication
//  date and site name go into the HTML, never into `datePublished`, which stays
//  nil (except on the pages imported from Matter, where it is the date they were
//  saved there) so every list sorts by the date saved. See Technotes/NetNewsList/Plan.md, D2.
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

	/// The title without the site's name after it ("Spending your effort / claude.dev Blog"),
	/// as page titles and Safari's shared titles usually carry it. Unchanged when the page
	/// names no site or the title doesn't end with it.
	static func storedTitle(_ title: String?, siteName: String?) -> String? {
		guard let title, let siteName = siteName?.trimmingCharacters(in: .whitespacesAndNewlines), !siteName.isEmpty else {
			return title
		}
		for separator in [" / ", " | ", " - ", " – ", " — ", " · ", " : ", " » "] {
			if let range = title.range(of: separator + siteName, options: [.caseInsensitive, .anchored, .backwards]) {
				let stripped = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
				if !stripped.isEmpty {
					return stripped
				}
			}
		}
		return title
	}

	/// A body handed in by the sender. HTML is kept as is (stored content never runs
	/// scripts); plain text becomes paragraphs. Nil when there is no text.
	static func storedHTML(forSuppliedBody body: String?) -> String? {
		guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
			return nil
		}
		if body.range(of: #"<(p|div|article|section|br|h[1-6]|ul|ol|li|blockquote|pre|img|a)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
			return body
		}
		let paragraphs = body.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
			.map { "<p>\($0.escapingSpecialXMLCharacters)</p>" }
		return paragraphs.joined(separator: "\n")
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
