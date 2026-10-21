//
//  HelpURL.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/29/25.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import Foundation

enum HelpURL: String {

	// NetNewsList has no website of its own; help lives with the code.
	case helpHome = "https://github.com/okbytes/NetNewsList#readme"
	case website = "https://github.com/okbytes/NetNewsList"
	case releaseNotes = "https://github.com/okbytes/NetNewsList/releases"

#if os(macOS)
	@MainActor func open() {
		Browser.open(rawValue)
	}
#endif
}
