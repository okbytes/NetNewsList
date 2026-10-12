//
//  Browser.swift
//  Evergren
//
//  Created by Brent Simmons on 2/23/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSWeb

@MainActor struct Browser {

	/// Opens a URL in the system’s default browser.
	///
	/// - Parameters:
	///   - urlString: The URL to open.
	///   - inBackground: Whether to keep NetNewsList in front. The app always opens pages in front;
	///     Shared `HelpURL` passes `false`.
	/// - Note: Some browsers (specifically Chromium-derived ones) will ignore the request
	///   to open in the background.
	static func open(_ urlString: String, inBackground: Bool = false) {
		guard let url = URL(string: urlString), let preparedURL = url.preparedForOpeningInBrowser() else { return }

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.requiresUniversalLinks = true
		configuration.promptsUserIfNeeded = false
		if inBackground {
			configuration.activates = false
		}

		NSWorkspace.shared.open(preparedURL, configuration: configuration) { _, error in
			Task { @MainActor in
				guard error != nil else {
					return
				}
				MacWebBrowser.openURL(url, inBackground: inBackground)
			}
		}
	}
}
