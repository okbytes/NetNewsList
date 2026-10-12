//
//  AppDefaults.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/22/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import AppKit

enum FontSize: Int {
	case small = 0
	case medium = 1
	case large = 2
	case veryLarge = 3
}

final class AppDefaults: Sendable {

	static let shared = AppDefaults()

	struct Key {
		static let firstRunDate = "firstRunDate"
		static let secureWindowState = "secureWindowState"
		static let lastImageCacheFlushDate = "lastImageCacheFlushDate"
		static let timelineFontSize = "timelineFontSize"
		static let timelineSortDirection = "timelineSortDirection"
		static let timelineGroupByFeed = "timelineGroupByFeed"
		static let detailFontSize = "detailFontSize"
		static let addFeedAccountID = "addFeedAccountID"
		static let addFeedFolderName = "addFeedFolderName"
		static let addFolderAccountID = "addFolderAccountID"

		// Hidden prefs
		static let showDebugMenu = "ShowDebugMenu"
		static let timelineShowsSeparators = "CorreiaSeparators"
		static let showTitleOnMainWindow = "KafasisTitleMode"
		static let feedDoubleClickMarkAsRead = "GruberFeedDoubleClickMarkAsRead"
		static let suppressSyncOnLaunch = "DevroeSuppressSyncOnLaunch"
		static let webInspectorEnabled = "WebInspectorEnabled"
		static let webInspectorStartsAttached = "__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached"
	}

	private static let smallestFontSizeRawValue = FontSize.small.rawValue
	private static let largestFontSizeRawValue = FontSize.veryLarge.rawValue

	let isFirstRun: Bool = {
		if UserDefaults.standard.object(forKey: Key.firstRunDate) is Date {
			return false
		}
		firstRunDate = Date()
		return true
	}()

	var secureWindowState: Data? {
		get {
			UserDefaults.standard.object(forKey: Key.secureWindowState) as? Data
		}
		set {
			UserDefaults.standard.set(newValue, forKey: Key.secureWindowState)
		}
	}

	var lastImageCacheFlushDate: Date? {
		get {
			return AppDefaults.date(for: Key.lastImageCacheFlushDate)
		}
		set {
			AppDefaults.setDate(for: Key.lastImageCacheFlushDate, newValue)
		}
	}

	var timelineFontSize: FontSize {
		get {
			return fontSize(for: Key.timelineFontSize)
		}
		set {
			AppDefaults.setFontSize(for: Key.timelineFontSize, newValue)
		}
	}

	var detailFontSize: FontSize {
		get {
			return fontSize(for: Key.detailFontSize)
		}
		set {
			AppDefaults.setFontSize(for: Key.detailFontSize, newValue)
		}
	}

	var addFeedAccountID: String? {
		get {
			return AppDefaults.string(for: Key.addFeedAccountID)
		}
		set {
			AppDefaults.setString(for: Key.addFeedAccountID, newValue)
		}
	}

	var addFeedFolderName: String? {
		get {
			return AppDefaults.string(for: Key.addFeedFolderName)
		}
		set {
			AppDefaults.setString(for: Key.addFeedFolderName, newValue)
		}
	}

	var addFolderAccountID: String? {
		get {
			return AppDefaults.string(for: Key.addFolderAccountID)
		}
		set {
			AppDefaults.setString(for: Key.addFolderAccountID, newValue)
		}
	}

	var showTitleOnMainWindow: Bool {
		return AppDefaults.bool(for: Key.showTitleOnMainWindow)
	}

	var showDebugMenu: Bool {
		return AppDefaults.bool(for: Key.showDebugMenu)
 	}

	var feedDoubleClickMarkAsRead: Bool {
		get {
			return AppDefaults.bool(for: Key.feedDoubleClickMarkAsRead)
		}
		set {
			AppDefaults.setBool(for: Key.feedDoubleClickMarkAsRead, newValue)
		}
	}

	var suppressSyncOnLaunch: Bool {
		get {
			return AppDefaults.bool(for: Key.suppressSyncOnLaunch)
		}
		set {
			AppDefaults.setBool(for: Key.suppressSyncOnLaunch, newValue)
		}
	}

	var webInspectorEnabled: Bool {
		get {
			return AppDefaults.bool(for: Key.webInspectorEnabled)
		}
		set {
			AppDefaults.setBool(for: Key.webInspectorEnabled, newValue)
		}
	}

	var webInspectorStartsAttached: Bool {
		get {
			return AppDefaults.bool(for: Key.webInspectorStartsAttached)
		}
		set {
			AppDefaults.setBool(for: Key.webInspectorStartsAttached, newValue)
		}
	}

	// Sorting is per window and lives in TimelineWindowState. These two are read-only seeds
	// for a window that has no saved sort, so a setting from before per-window sorting carries over.
	var timelineSortDirection: ComparisonResult {
		AppDefaults.sortDirection(for: Key.timelineSortDirection)
	}

	var timelineGroupByFeed: Bool {
		AppDefaults.bool(for: Key.timelineGroupByFeed)
	}

	var timelineShowsSeparators: Bool {
		return AppDefaults.bool(for: Key.timelineShowsSeparators)
	}

	/// There’s no setting for it: articles are always shown at this size.
	var articleTextSize: ArticleTextSize {
		.large
	}

	@MainActor func registerDefaults() {
		#if DEBUG
 		let showDebugMenu = true
 		#else
 		let showDebugMenu = false
 		#endif

		let defaults: [String: Any] = [
			Key.timelineFontSize: FontSize.medium.rawValue,
			Key.detailFontSize: FontSize.medium.rawValue,
			// Oldest first, so the Queue reads in the order pages were saved.
			Key.timelineSortDirection: ComparisonResult.orderedAscending.rawValue,
			Key.timelineGroupByFeed: false,
			"NSScrollViewShouldScrollUnderTitlebar": false,
			Key.showDebugMenu: showDebugMenu
		]

		UserDefaults.standard.register(defaults: defaults)
	}

	func actualFontSize(for fontSize: FontSize) -> CGFloat {
		switch fontSize {
		case .small:
			return NSFont.systemFontSize
		case .medium:
			return actualFontSize(for: .small) + 1.0
		case .large:
			return actualFontSize(for: .medium) + 4.0
		case .veryLarge:
			return actualFontSize(for: .large) + 8.0
		}
	}
}

private extension AppDefaults {

	static var firstRunDate: Date? {
		get {
			return AppDefaults.date(for: Key.firstRunDate)
		}
		set {
			AppDefaults.setDate(for: Key.firstRunDate, newValue)
		}
	}

	func fontSize(for key: String) -> FontSize {
		// Punted till after 1.0.
		return .medium

//		var rawFontSize = int(for: key)
//		if rawFontSize < smallestFontSizeRawValue {
//			rawFontSize = smallestFontSizeRawValue
//		}
//		if rawFontSize > largestFontSizeRawValue {
//			rawFontSize = largestFontSizeRawValue
//		}
//		return FontSize(rawValue: rawFontSize)!
	}

	static func setFontSize(for key: String, _ fontSize: FontSize) {
		setInt(for: key, fontSize.rawValue)
	}

	static func string(for key: String) -> String? {
		return UserDefaults.standard.string(forKey: key)
	}

	static func setString(for key: String, _ value: String?) {
		UserDefaults.standard.set(value, forKey: key)
	}

	static func bool(for key: String) -> Bool {
		return UserDefaults.standard.bool(forKey: key)
	}

	static func setBool(for key: String, _ flag: Bool) {
		UserDefaults.standard.set(flag, forKey: key)
	}

	static func int(for key: String) -> Int {
		return UserDefaults.standard.integer(forKey: key)
	}

	static func setInt(for key: String, _ x: Int) {
		UserDefaults.standard.set(x, forKey: key)
	}

	static func date(for key: String) -> Date? {
		return UserDefaults.standard.object(forKey: key) as? Date
	}

	static func setDate(for key: String, _ date: Date?) {
		UserDefaults.standard.set(date, forKey: key)
	}

	static func sortDirection(for key: String) -> ComparisonResult {
		let rawInt = int(for: key)
		if rawInt == ComparisonResult.orderedAscending.rawValue {
			return .orderedAscending
		}
		return .orderedDescending
	}
}
