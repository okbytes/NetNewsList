//
//  DroppedWebPages.swift
//  NetNewsList
//
//  Web addresses dragged onto the timeline, from a browser’s address bar,
//  a link or text. Each one is saved.
//

import AppKit

@MainActor enum DroppedWebPages {

	static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.URL, .string]

	/// The link title browsers attach to a dragged link.
	private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

	/// Each item’s link or address, with the title a browser gives a dragged link. Text with other
	/// words in it gives the addresses it holds when no link comes with it, or when the link is
	/// the first of them (lines of links, which come with only the first as a link). A dragged
	/// article or a named link is the link alone, whatever addresses its text holds.
	static func pages(on pasteboard: NSPasteboard) -> [SavedArticleRequest] {
		(pasteboard.pasteboardItems ?? []).flatMap { item -> [SavedArticleRequest] in
			let link = item.string(forType: .URL)
			let isNamed = item.types.contains(urlNameType) || item.types.contains(ArticlePasteboardWriter.articleUTIType)
			if !isNamed, let text = item.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), text.contains(where: \.isWhitespace) {
				let addresses = SavePageService.webAddresses(in: text)
				if link == nil || addresses.first == link {
					return addresses.map { SavedArticleRequest(url: $0, title: nil) }
				}
			}
			guard let string = link ?? item.string(forType: .string) else {
				return []
			}
			// URL(string:) would take text with spaces in it as one address, percent-encoding them.
			let urlString = string.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !urlString.contains(where: \.isWhitespace), let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
				return []
			}
			let title = item.string(forType: urlNameType)?.trimmingCharacters(in: .whitespacesAndNewlines)
			return [SavedArticleRequest(url: urlString, title: (title?.isEmpty ?? true) ? nil : title)]
		}
	}

	/// Saves the pages. A page that can’t be saved opens in the Add Article sheet.
	@discardableResult
	static func save(_ pages: [SavedArticleRequest]) -> Bool {
		guard !pages.isEmpty else {
			return false
		}
		Task { @MainActor in
			for page in pages {
				do {
					try await ExtractionCoordinator.shared.saveArticle(url: page.url, title: page.title)
				} catch {
					appDelegate.addArticle(page.url, title: page.title)
				}
			}
		}
		return true
	}
}
