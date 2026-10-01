//
//  DroppedWebPages.swift
//  NetNewsList
//
//  Web addresses dragged onto the sidebar or the timeline, from a browser’s
//  address bar, a link or text. Each one is saved.
//

import AppKit

@MainActor enum DroppedWebPages {

	static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.URL, .string]

	/// The link title browsers attach to a dragged link.
	private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

	static func pages(on pasteboard: NSPasteboard) -> [SavedArticleRequest] {
		(pasteboard.pasteboardItems ?? []).compactMap { item in
			guard let string = item.string(forType: .URL) ?? item.string(forType: .string) else {
				return nil
			}
			let urlString = string.trimmingCharacters(in: .whitespacesAndNewlines)
			guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
				return nil
			}
			let title = item.string(forType: urlNameType)?.trimmingCharacters(in: .whitespacesAndNewlines)
			return SavedArticleRequest(url: urlString, title: (title?.isEmpty ?? true) ? nil : title)
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
