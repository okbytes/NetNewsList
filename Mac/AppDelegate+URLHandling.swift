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
		guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
			return
		}

		// Save a page: netnewslist://add?url={url}&title={title}
		if let url = URL(string: urlString), let request = AddArticleURLScheme.request(from: url) {
			saveArticle(from: request)
			return
		}

		// Handle themes
		if urlString.hasPrefix("netnewslist://theme/") {
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
	}

	/// Saves without showing anything, then hands the focus back to the app that asked
	/// (a browser, usually), so saving from the browser doesn’t pull you out of it.
	/// When the page can’t be saved, the Add Article sheet opens with it filled in.
	private func saveArticle(from request: SavedArticleRequest) {
		let requestingApp = NSWorkspace.shared.frontmostApplication
		Task { @MainActor in
			do {
				try await ExtractionCoordinator.shared.saveArticle(url: request.url, title: request.title)
				if let requestingApp, requestingApp != NSRunningApplication.current {
					requestingApp.activate()
				}
			} catch {
				self.addArticle(request.url, title: request.title)
			}
		}
	}
}
