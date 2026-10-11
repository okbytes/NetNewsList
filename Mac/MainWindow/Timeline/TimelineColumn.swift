//
//  TimelineColumn.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import AppKit

/// The columns of the timeline in column layout, in default order.
enum TimelineColumn: String, CaseIterable {
	case feed
	case title
	case date

	private static let titleColumnWidth: CGFloat = 400.0
	private static let titleColumnMinimumWidth: CGFloat = 100.0
	private static let feedColumnWidth: CGFloat = 180.0
	private static let feedColumnMinimumWidth: CGFloat = 80.0
	private static let dateColumnWidth: CGFloat = 130.0
	private static let dateColumnMinimumWidth: CGFloat = 70.0
	private static let textColumnMaximumWidth: CGFloat = 2000.0

	var identifier: NSUserInterfaceItemIdentifier {
		NSUserInterfaceItemIdentifier(rawValue: rawValue)
	}

	init?(identifier: NSUserInterfaceItemIdentifier) {
		self.init(rawValue: identifier.rawValue)
	}

	var sortKey: ArticleSortKey {
		switch self {
		case .title:
			.title
		case .feed:
			.feed
		case .date:
			.date
		}
	}

	@MainActor func makeTableColumn() -> NSTableColumn {
		let column = NSTableColumn(identifier: identifier)
		column.headerCell = TimelineColumnHeaderCell(textCell: sortKey.localizedName)
		column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: sortKey.sortsAscendingFirst)

		switch self {
		case .title:
			column.width = Self.titleColumnWidth
			column.minWidth = Self.titleColumnMinimumWidth
			column.maxWidth = Self.textColumnMaximumWidth
			// The only column that absorbs window resizing.
			column.resizingMask = [.userResizingMask, .autoresizingMask]
		case .feed:
			column.width = Self.feedColumnWidth
			column.minWidth = Self.feedColumnMinimumWidth
			column.maxWidth = Self.textColumnMaximumWidth
			column.resizingMask = .userResizingMask
		case .date:
			column.width = Self.dateColumnWidth
			column.minWidth = Self.dateColumnMinimumWidth
			column.maxWidth = Self.textColumnMaximumWidth
			column.resizingMask = .userResizingMask
		}

		return column
	}
}

/// Adds a little room between the column separator and the title, as Mail has.
final class TimelineColumnHeaderCell: NSTableHeaderCell {

	private static let titleLeftPadding: CGFloat = 6.0

	override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
		var frame = cellFrame
		frame.origin.x += Self.titleLeftPadding
		frame.size.width -= Self.titleLeftPadding
		super.drawInterior(withFrame: frame, in: controlView)
	}
}
