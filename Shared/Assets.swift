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

		static let starOpen = RSImage(symbol: "star")!
		static let starClosed = RSImage(symbol: "star.fill")!
		static let copy = RSImage(symbol: "document.on.document")
		static var markAllAsRead: RSImage { RSImage(named: "markAllAsRead")! }
		static let nextUnread = RSImage(symbol: "chevron.down.circle")!

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
		static let starredFeed = IconImage(starClosed, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.star)

#if os(macOS)
		static let addNewSidebarItem = RSImage(symbol: "plus")!
		static let articleTheme = RSImage(symbol: "doc.richtext")!
		static let cleanUp = RSImage(symbol: "bubbles.and.sparkles")!
		static var marsEdit: RSImage { RSImage(named: "MarsEditIcon")! }
		static var microblog: RSImage { RSImage(named: "MicroblogIcon")! }
		static let filterActive = RSImage(symbol: "line.horizontal.3.decrease.circle.fill")!
		static let filterInactive = RSImage(symbol: "line.horizontal.3.decrease.circle")!
		static let openInBrowser = RSImage(symbol: "safari")!
		static let preferencesToolbarGeneral = RSImage(symbol: "gearshape")!
		static let readClosed = RSImage(symbol: "largecircle.fill.circle")!
		static let readOpen = RSImage(symbol: "circle")!
		static let refresh = RSImage(symbol: "arrow.clockwise")!
		static let swipeMarkUnstarred = RSImage(symbol: "star")!
		static var timelineStar: RSImage { RSImage(named: "timelineStar")! }
		static var markBelowAsRead: RSImage { RSImage(named: "markBelowAsRead")! }
		static var markAboveAsRead: RSImage { RSImage(named: "markAboveAsRead")! }
		static let searchFeed = IconImage(RSImage(named: NSImage.smartBadgeTemplateName)!, isSymbol: true, isBackgroundSuppressed: true)
		static let swipeMarkStarred = RSImage(systemSymbolName: "star.fill", accessibilityDescription: "Star")!
		static let swipeMarkRead = RSImage(systemSymbolName: "circle", accessibilityDescription: "Mark Read")!
		static let swipeMarkUnread = RSImage(systemSymbolName: "largecircle.fill.circle", accessibilityDescription: "Mark Unread")!
		static let mainFolder = IconImage(folder, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.primaryAccent)
		static let todayFeed = IconImage(RSImage(symbol: "sun.max.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: NSColor.orange)
		static let unreadFeed = IconImage(RSImage(symbol: "largecircle.fill.circle")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.primaryAccent)

#else // iOS

		static let circleClosed = RSImage(symbol: "largecircle.fill.circle")!
		static let markBelowAsRead = RSImage(symbol: "arrowtriangle.down.circle")!
		static let markAboveAsRead = RSImage(symbol: "arrowtriangle.up.circle")!
		static let more = RSImage(symbol: "ellipsis.circle")!
		static let nextArticle = RSImage(symbol: "chevron.down")!
		static let circleOpen = RSImage(symbol: "circle")!
		static var disclosure: RSImage { RSImage(named: "disclosure")! }
		static let deactivate = RSImage(symbol: "minus.circle")!
		static let currentActivity = RSImage(symbol: "text.pad.header")!
		static let edit = RSImage(symbol: "square.and.pencil")!
		static let filter = RSImage(symbol: "line.3.horizontal.decrease")!
		static let folderOutlinePlus = RSImage(symbol: "folder.badge.plus")!
		static let info = RSImage(symbol: "info.circle")!
		static let plus = RSImage(symbol: "plus")!
		static let prevArticle = RSImage(symbol: "chevron.up")!
		static let openInSidebar = RSImage(symbol: "arrow.turn.down.left")!
		static let safari = RSImage(symbol: "safari")!
		static let smartFeed = RSImage(symbol: "gear")!
		static let trash = RSImage(symbol: "trash")!

		static let searchFeed = IconImage(RSImage(symbol: "magnifyingglass")!, isSymbol: true)
		static let mainFolder = IconImage(folder, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.secondaryAccent)
		static let todayFeed = IconImage(RSImage(symbol: "sun.max.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: UIColor.systemOrange)
		static let unreadFeed = IconImage(RSImage(symbol: "largecircle.fill.circle")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.secondaryAccent)
		static var timelineStar: RSImage {
			let image = RSImage(symbol: "star.fill")!
			return image.withTintColor(Assets.Colors.star, renderingMode: .alwaysOriginal)
		}
		static let unreadCellIndicator = IconImage(RSImage(symbol: "circle.fill")!, isSymbol: true, isBackgroundSuppressed: true, preferredColor: Assets.Colors.secondaryAccent)
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
		static let star = RSColor(named: "StarColor")!
		static let sidebarUnreadCountBackground = RSColor(named: "SidebarUnreadCountBackground")!
		static let sidebarUnreadCountText = RSColor(named: "SidebarUnreadCountText")!
#else // iOS
		static let primaryAccent = RSColor(named: "primaryAccentColor")!
		static let secondaryAccent = RSColor(named: "secondaryAccentColor")!
		static let star = RSColor(named: "starColor")!
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
