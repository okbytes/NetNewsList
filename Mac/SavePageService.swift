//
//  SavePageService.swift
//  NetNewsList
//
//  The “Save to NetNewsList” item in the Services menu (NSServices in Info.plist):
//  saves the web addresses in what is selected in any app, from right-click › Services.
//

import AppKit

@MainActor final class SavePageService: NSObject {

	static let shared = SavePageService()

	/// Makes the service available. Called at launch; the service starts the app if it isn’t running.
	func register() {
		NSApplication.shared.servicesProvider = self
		NSUpdateDynamicServices()
	}

	/// The `NSMessage` in Info.plist’s NSServices entry. A page that can’t be saved opens in the
	/// Add Article sheet, as for a dropped link.
	@objc func savePages(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
		let pages = Self.pages(on: pasteboard)
		guard !pages.isEmpty else {
			error.pointee = NSLocalizedString("There’s no web address in the selection.", comment: "Services error") as NSString
			return
		}
		DroppedWebPages.save(pages)
	}

	/// A selected link or address, or else every web address in the selected text.
	static func pages(on pasteboard: NSPasteboard) -> [SavedArticleRequest] {
		let linkedPages = DroppedWebPages.pages(on: pasteboard)
		if !linkedPages.isEmpty {
			return linkedPages
		}
		guard let text = pasteboard.string(forType: .string) else {
			return []
		}
		return webAddresses(in: text).map { SavedArticleRequest(url: $0, title: nil) }
	}

	/// The http and https addresses in the text, in order, each once. An address written
	/// without a scheme, such as `example.com/page`, counts as http.
	static func webAddresses(in text: String) -> [String] {
		guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
			return []
		}
		var addresses = [String]()
		var seen = Set<String>()
		for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
			guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
				continue
			}
			let address = url.absoluteString
			if seen.insert(address).inserted {
				addresses.append(address)
			}
		}
		return addresses
	}
}
