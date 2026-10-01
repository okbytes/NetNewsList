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
	case releaseNotes = "https://github.com/okbytes/NetNewsList/commits/"
	case howToSupportNetNewsWire = "https://netnewswire.com/"
	case githubRepo = "https://github.com/okbytes/NetNewsList/tree/main"
	case bugTracker = "https://github.com/okbytes/NetNewsList/issues"
	case discourse = "https://github.com/okbytes/NetNewsList/discussions"
	case technotes = "https://github.com/okbytes/NetNewsList/tree/main/Technotes/NetNewsList"
	case privacyPolicy = "https://github.com/okbytes/NetNewsList/blob/main/Technotes/NetNewsList/Privacy.md"

#if os(macOS)
	@MainActor func open() {
		Browser.open(self.rawValue, inBackground: false)
	}
#endif
}
