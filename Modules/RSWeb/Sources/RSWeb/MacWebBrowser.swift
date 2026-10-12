//
//  MacWebBrowser.swift
//  RSWeb
//
//  Created by Brent Simmons on 12/27/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

#if os(macOS)
import AppKit

@MainActor public final class MacWebBrowser {

	/// Opens a URL in the default browser.
	@discardableResult public static func openURL(_ url: URL) -> Bool {
		guard let preparedURL = url.preparedForOpeningInBrowser() else {
			return false
		}
		return NSWorkspace.shared.open(preparedURL)
	}
}

#endif
