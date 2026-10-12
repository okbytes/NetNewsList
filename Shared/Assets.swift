//
//  Assets.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 11/18/25.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

import RSCore
import Images

#if os(macOS)
typealias RSColor = NSColor
#else
typealias RSColor = UIColor
#endif

struct Assets {
	@MainActor struct Images {
		static let copy = RSImage(symbol: "document.on.document")

		nonisolated static var nnwFeedIcon: RSImage { RSImage(named: "nnwFeedIcon")! }
		static var faviconTemplate: RSImage { RSImage(named: "faviconTemplateImage")! }

		static let share = RSImage(symbol: "square.and.arrow.up")!
		/// Archive an article: from the Queue to the Archive.
		static let archive = RSImage(symbol: "archivebox")!
		/// Move an archived article back to the Queue.
		static let moveToQueue = RSImage(symbol: "tray.and.arrow.up")!
		/// The "…" menu with the Archive (and Settings on iOS).
		static let listMenu = RSImage(symbol: "ellipsis")!

#if os(macOS)
		static let addNewSidebarItem = RSImage(symbol: "plus")!
		static let openInBrowser = RSImage(symbol: "safari")!
		static let unreadFeed = IconImage(RSImage(symbol: "tray.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.primaryAccent)
		static let archiveFeed = IconImage(RSImage(symbol: "archivebox.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: NSColor.systemBrown)

#else // iOS

		static let circleClosed = RSImage(symbol: "largecircle.fill.circle")!
		static let more = RSImage(symbol: "ellipsis.circle")!
		static let circleOpen = RSImage(symbol: "circle")!
		static let safari = RSImage(symbol: "safari")!
		static let trash = RSImage(symbol: "trash")!

		static let unreadFeed = IconImage(RSImage(symbol: "tray.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.secondaryAccent)
		static let archiveFeed = IconImage(RSImage(symbol: "archivebox.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: UIColor.systemBrown)
#endif
	}

	@MainActor struct Colors {
#if os(macOS)
		static let primaryAccent = RSColor(named: "AccentColor")!
		static let timelineSeparator = NSColor(named: "timelineSeparatorColor")!
		static let iconLightBackground = NSColor(named: "iconLightBackgroundColor")!
		static let iconDarkBackground = NSColor(named: "iconDarkBackgroundColor")!
#else // iOS
		static let primaryAccent = RSColor(named: "primaryAccentColor")!
		static let secondaryAccent = RSColor(named: "secondaryAccentColor")!
		static let vibrantText = RSColor(named: "vibrantTextColor")!
		static let iconBackground = RSColor(named: "iconBackgroundColor")!
		static let fullScreenBackground = RSColor(named: "fullScreenBackgroundColor")!
#endif
	}
}

extension RSImage {

	convenience init?(symbol: String) {
#if os(macOS)
		self.init(systemSymbolName: symbol, accessibilityDescription: nil)
#else // iOS
		self.init(systemName: symbol)
#endif
	}
}
