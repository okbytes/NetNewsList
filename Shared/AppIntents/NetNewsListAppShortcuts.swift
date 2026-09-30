//
//  NetNewsListAppShortcuts.swift
//  NetNewsList
//
//  Makes the App Intents available in Shortcuts, Spotlight and Siri with no setup.
//

import AppIntents

struct NetNewsListAppShortcuts: AppShortcutsProvider {

	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: SaveArticleIntent(),
			phrases: [
				"Save a page to \(.applicationName)",
				"Add to \(.applicationName)"
			],
			shortTitle: "Save Page",
			systemImageName: "tray.and.arrow.down"
		)
	}
}
