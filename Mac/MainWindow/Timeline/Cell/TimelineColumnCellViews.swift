//
//  TimelineColumnCellViews.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import AppKit

// Cell views for the timeline’s column layout. Selection state arrives through backgroundStyle,
// which the standard NSTableRowView sets, so no custom row view is needed.

private let columnCellHorizontalPadding: CGFloat = 8.0
private let feedIconDimension: CGFloat = 16.0
private let feedIconMarginRight: CGFloat = 5.0

/// Single line of truncating text — used for the Title and Date columns.
final class TimelineTextColumnCellView: NSTableCellView {

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		let label = Self.makeLabel()
		addSubview(label)
		textField = label
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: columnCellHorizontalPadding),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -columnCellHorizontalPadding),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	static func makeLabel() -> NSTextField {
		let label = NSTextField(labelWithString: "")
		label.translatesAutoresizingMaskIntoConstraints = false
		label.lineBreakMode = .byTruncatingTail
		label.maximumNumberOfLines = 1
		label.cell?.truncatesLastVisibleLine = true
		label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return label
	}
}

/// Feed icon plus feed name.
final class TimelineFeedColumnCellView: NSTableCellView {

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		let iconView = NSImageView()
		iconView.translatesAutoresizingMaskIntoConstraints = false
		iconView.imageScaling = .scaleProportionallyDown
		iconView.wantsLayer = true
		iconView.layer?.cornerRadius = 2.0
		iconView.layer?.masksToBounds = true
		addSubview(iconView)
		imageView = iconView

		let label = TimelineTextColumnCellView.makeLabel()
		addSubview(label)
		textField = label

		NSLayoutConstraint.activate([
			iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: columnCellHorizontalPadding),
			iconView.widthAnchor.constraint(equalToConstant: feedIconDimension),
			iconView.heightAnchor.constraint(equalToConstant: feedIconDimension),
			iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
			label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: feedIconMarginRight),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -columnCellHorizontalPadding),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
}
