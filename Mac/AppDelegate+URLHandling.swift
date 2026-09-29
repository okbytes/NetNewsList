//
//  AppDelegate+URLHandling.swift
//  NetNewsWire
//
//  Handles URLs sent to the app through the GetURL Apple Event
//  (custom URL schemes registered in Info.plist).
//

import AppKit

extension AppDelegate {

	func installAppleEventHandlers() {
		NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(AppDelegate.getURL(_:_:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
	}

	@objc func getURL(_ event: NSAppleEventDescriptor, _ withReplyEvent: NSAppleEventDescriptor) {
		guard var urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
			return
		}

		// Handle themes
		if urlString.hasPrefix("netnewswire://theme/") {
			guard let comps = URLComponents(string: urlString),
				  let queryItems = comps.queryItems,
				  let themeURLString = queryItems.first(where: { $0.name == "url" })?.value else {
				return
			}

			if let themeURL = URL(string: themeURLString) {
				ArticleThemeDownloader.shared.downloadTheme(from: themeURL)
			}
			return
		}

		// Special case URL with specific scheme handler x-netnewswire-feed: intended to ensure we open
		// it regardless of which news reader may be set as the default
		let nnwScheme = "x-netnewswire-feed:"
		if urlString.hasPrefix(nnwScheme) {
			urlString = urlString.replacingOccurrences(of: nnwScheme, with: "feed:")
		}

		let normalizedURLString = urlString.normalizedURL
		if !normalizedURLString.mayBeURL {
			return
		}

		DispatchQueue.main.async {
			self.addFeed(normalizedURLString)
		}
	}
}
