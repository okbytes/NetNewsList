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

	/// Opens a URL in front, in the system’s default browser.
	static func open(_ urlString: String) {
		guard let url = URL(string: urlString), let preparedURL = url.preparedForOpeningInBrowser() else {
			return
		}

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.requiresUniversalLinks = true
		configuration.promptsUserIfNeeded = false

		NSWorkspace.shared.open(preparedURL, configuration: configuration) { _, error in
			Task { @MainActor in
				guard error != nil else {
					return
				}
				MacWebBrowser.openURL(url)
			}
		}
	}
}
