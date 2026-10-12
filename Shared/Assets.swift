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
import Account
import Images

#if os(macOS)
typealias RSColor = NSColor
#else
typealias RSColor = UIColor
#endif

struct Assets {
	@MainActor struct Images {
		static var accountCloudKit: RSImage { RSImage(named: "accountCloudKit")! }

		static let copy = RSImage(symbol: "document.on.document")
		static var markAllAsRead: RSImage { RSImage(named: "markAllAsRead")! }

		nonisolated static var nnwFeedIcon: RSImage { RSImage(named: "nnwFeedIcon")! }
		static var faviconTemplate: RSImage { RSImage(named: "faviconTemplateImage")! }

		static let showOriginal = RSImage(symbol: "globe")!
		static let showSavedPage: RSImage = {
			if #available(iOS 18, macOS 15, *) {
				return RSImage(symbol: "text.page")!
			} else {
				return RSImage(symbol: "doc.plaintext")!
			}
		}()
		static let share = RSImage(symbol: "square.and.arrow.up")!
		static let folder = RSImage(symbol: "folder")!
		/// Archive an article: from the Queue to the Archive.
		static let archive = RSImage(symbol: "archivebox")!
		/// Move an archived article back to the Queue.
		static let moveToQueue = RSImage(symbol: "tray.and.arrow.up")!
		/// The "…" menu with the Archive (and Settings on iOS).
		static let listMenu = RSImage(symbol: "ellipsis")!

#if os(macOS)
		static let addNewSidebarItem = RSImage(symbol: "plus")!
		static let articleTheme = RSImage(symbol: "doc.richtext")!
		static var marsEdit: RSImage { RSImage(named: "MarsEditIcon")! }
		static var microblog: RSImage { RSImage(named: "MicroblogIcon")! }
		static let openInBrowser = RSImage(symbol: "safari")!
		static let preferencesToolbarGeneral = RSImage(symbol: "gearshape")!
		static let readClosed = RSImage(symbol: "largecircle.fill.circle")!
		static let readOpen = RSImage(symbol: "circle")!
		static let refresh = RSImage(symbol: "arrow.clockwise")!
		static let searchFeed = IconImage(RSImage(named: NSImage.smartBadgeTemplateName)!, isSymbol: true, isBackgroundSuppressed: true)
		static let swipeMarkRead = RSImage(systemSymbolName: "circle", accessibilityDescription: "Mark Read")!
		static let swipeMarkUnread = RSImage(systemSymbolName: "largecircle.fill.circle", accessibilityDescription: "Mark Unread")!
		static let mainFolder = IconImage(folder, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.primaryAccent)
		static let unreadFeed = IconImage(RSImage(symbol: "tray.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.primaryAccent)
		static let archiveFeed = IconImage(RSImage(symbol: "archivebox.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: NSColor.systemBrown)

#else // iOS

		static let circleClosed = RSImage(symbol: "largecircle.fill.circle")!
		static let more = RSImage(symbol: "ellipsis.circle")!
		static let nextArticle = RSImage(symbol: "chevron.down")!
		static let circleOpen = RSImage(symbol: "circle")!
		static var disclosure: RSImage { RSImage(named: "disclosure")! }
		static let deactivate = RSImage(symbol: "minus.circle")!
		static let currentActivity = RSImage(symbol: "text.pad.header")!
		static let info = RSImage(symbol: "info.circle")!
		static let prevArticle = RSImage(symbol: "chevron.up")!
		static let safari = RSImage(symbol: "safari")!
		static let smartFeed = RSImage(symbol: "gear")!
		static let trash = RSImage(symbol: "trash")!

		static let searchFeed = IconImage(RSImage(symbol: "magnifyingglass")!, isSymbol: true)
		static let mainFolder = IconImage(folder, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.secondaryAccent)
		static let unreadFeed = IconImage(RSImage(symbol: "tray.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.secondaryAccent)
		static let archiveFeed = IconImage(RSImage(symbol: "archivebox.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: UIColor.systemBrown)
#endif
	}

	@MainActor static func accountImage(_ accountType: AccountType) -> RSImage {
		switch accountType {
		case .cloudKit:
			return Assets.Images.accountCloudKit
		}
	}

	@MainActor struct Colors {
#if os(macOS)
		static let primaryAccent = RSColor(named: "AccentColor")!
		static let timelineSeparator = NSColor(named: "timelineSeparatorColor")!
		static let iconLightBackground = NSColor(named: "iconLightBackgroundColor")!
		static let iconDarkBackground = NSColor(named: "iconDarkBackgroundColor")!
		static let sidebarUnreadCountBackground = RSColor(named: "SidebarUnreadCountBackground")!
		static let sidebarUnreadCountText = RSColor(named: "SidebarUnreadCountText")!
#else // iOS
		static let primaryAccent = RSColor(named: "primaryAccentColor")!
		static let secondaryAccent = RSColor(named: "secondaryAccentColor")!
		static let vibrantText = RSColor(named: "vibrantTextColor")!
		static let controlBackground = RSColor(named: "controlBackgroundColor")!
		static let iconBackground = RSColor(named: "iconBackgroundColor")!
		static let fullScreenBackground = RSColor(named: "fullScreenBackgroundColor")!
		static let sectionHeader = RSColor(named: "sectionHeaderColor")!
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
