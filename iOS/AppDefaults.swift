//
//  AppDefaults.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/22/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import RSCore
import UIKit
import os
import Account
import Articles
import Images

final class AppDefaults: Sendable {
	static let shared = AppDefaults()
	fileprivate static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AppDefaults")

	private init() {}

	nonisolated(unsafe) static let store: UserDefaults = {
		let appIdentifierPrefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as! String
		let suiteName = "\(appIdentifierPrefix)group.\(Bundle.main.bundleIdentifier!)"
		return UserDefaults.init(suiteName: suiteName)!
	}()

	struct Key {
		static let lastImageCacheFlushDate = "lastImageCacheFlushDate"
		static let firstRunDate = "firstRunDate"
		static let timelineSortDirection = "timelineSortDirection"
		static let articleWindowScrollY = "articleWindowScrollY"
		static let selectedArticle = "selectedArticle"
		static let timelineWidth = "timelineWidth"
	}

	let isFirstRun: Bool = {
		if AppDefaults.store.object(forKey: Key.firstRunDate) is Date {
			return false
		}
		firstRunDate = Date()
		return true
	}()

	var lastImageCacheFlushDate: Date? {
		get {
			return AppDefaults.date(for: Key.lastImageCacheFlushDate)
		}
		set {
			AppDefaults.setDate(for: Key.lastImageCacheFlushDate, newValue)
		}
	}

	var timelineSortDirection: ComparisonResult {
		get {
			return AppDefaults.sortDirection(for: Key.timelineSortDirection)
		}
		set {
			AppDefaults.setSortDirection(for: Key.timelineSortDirection, newValue)
		}
	}

	// The iPad list column width. nil until the user has resized it.
	var timelineWidth: Int? {
		get {
			UserDefaults.standard.object(forKey: Key.timelineWidth) as? Int
		}
		set {
			if let newValue {
				UserDefaults.standard.set(newValue, forKey: Key.timelineWidth)
			} else {
				UserDefaults.standard.removeObject(forKey: Key.timelineWidth)
			}
		}
	}

	var articleWindowScrollY: Int {
		get {
			UserDefaults.standard.integer(forKey: Key.articleWindowScrollY)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: Key.articleWindowScrollY)
		}
	}

	var selectedArticle: ArticleSpecifier? {
		get {
			guard let d = UserDefaults.standard.dictionary(forKey: Key.selectedArticle) as? [String: String] else {
				return nil
			}
			return ArticleSpecifier(dictionary: d)
		}
		set {
			guard let newValue else {
				UserDefaults.standard.removeObject(forKey: Key.selectedArticle)
				return
			}
			UserDefaults.standard.set(newValue.dictionary, forKey: Key.selectedArticle)
		}
	}

	@MainActor static func registerDefaults() {
		let defaults: [String: Any] = [// Oldest first: a reading list is read in the order it was saved.
										Key.timelineSortDirection: ComparisonResult.orderedAscending.rawValue]
		AppDefaults.store.register(defaults: defaults)
	}
}

private extension AppDefaults {

	static var firstRunDate: Date? {
		get {
			return date(for: Key.firstRunDate)
		}
		set {
			setDate(for: Key.firstRunDate, newValue)
		}
	}

	static func int(for key: String) -> Int {
		return AppDefaults.store.integer(forKey: key)
	}

	static func setInt(for key: String, _ x: Int) {
		AppDefaults.store.set(x, forKey: key)
	}

	static func date(for key: String) -> Date? {
		return AppDefaults.store.object(forKey: key) as? Date
	}

	static func setDate(for key: String, _ date: Date?) {
		AppDefaults.store.set(date, forKey: key)
	}

	static func sortDirection(for key: String) -> ComparisonResult {
		let rawInt = int(for: key)
		if rawInt == ComparisonResult.orderedAscending.rawValue {
			return .orderedAscending
		}
		return .orderedDescending
	}

	static func setSortDirection(for key: String, _ value: ComparisonResult) {
		if value == .orderedAscending {
			setInt(for: key, ComparisonResult.orderedAscending.rawValue)
		} else {
			setInt(for: key, ComparisonResult.orderedDescending.rawValue)
		}
	}
}

/// What launch restores: the open article (if it's still in the Queue) and its scroll position.
struct StateRestorationInfo {
	let selectedArticle: ArticleSpecifier?
	let articleWindowScrollY: Int

	init() {
		let selectedArticle = AppDefaults.shared.selectedArticle
		let articleWindowScrollY = AppDefaults.shared.articleWindowScrollY

		self.selectedArticle = selectedArticle
		self.articleWindowScrollY = articleWindowScrollY

		AppDefaults.logger.debug("AppDefaults: StateRestorationInfo:\nselectedArticle: \(selectedArticle?.dictionary ?? [String: String]())\narticleWindowScrollY: \(articleWindowScrollY)")
	}
}
