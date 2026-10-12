//
//  TimelineCellAppearance.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/6/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import AppKit

struct TimelineCellAppearance: Equatable {

	let showIcon: Bool

	let cellPadding: NSEdgeInsets

	let feedNameFont: NSFont

	let dateFont: NSFont
	let dateMarginLeft: CGFloat = 8.0

	let titleFont: NSFont
	let titleBottomMargin: CGFloat = 1.0
	// One line of text per row, like iOS: the title, or the summary when there is no title.
	let titleNumberOfLines = 1

	let textFont: NSFont

	let textOnlyFont: NSFont

	let drawsGrid = false

	let iconSize = NSSize(width: 24, height: 24)
	let iconMarginLeft: CGFloat = 8.0
	let iconMarginRight: CGFloat = 8.0
	let iconAdjustmentTop: CGFloat = 4.0
	let iconCornerRadius: CGFloat = 4.0

	init(showIcon: Bool, fontSize: FontSize) {

		let actualFontSize = AppDefaults.shared.actualFontSize(for: fontSize)
		let smallItemFontSize = floor(actualFontSize * 0.90)
		let largeItemFontSize = actualFontSize

		self.feedNameFont = NSFont.systemFont(ofSize: smallItemFontSize)
		self.dateFont = NSFont.systemFont(ofSize: smallItemFontSize)
		self.titleFont = NSFont.systemFont(ofSize: largeItemFontSize, weight: NSFont.Weight.semibold)
		self.textFont = NSFont.systemFont(ofSize: largeItemFontSize)
		self.textOnlyFont = NSFont.systemFont(ofSize: largeItemFontSize)

		self.showIcon = showIcon

		cellPadding = NSEdgeInsets(top: 8.0, left: 4.0, bottom: 10.0, right: 4.0)
	}
}

extension NSEdgeInsets: @retroactive Equatable {

	public static func ==(lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
		return lhs.left == rhs.left && lhs.top == rhs.top && lhs.right == rhs.right && lhs.bottom == rhs.bottom
	}
}
