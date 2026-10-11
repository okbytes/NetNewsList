//
//  UnreadCountView.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 11/22/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import AppKit

final class UnreadCountView: NSView {

	@MainActor struct Appearance {

		static let padding = NSEdgeInsets(top: 1.0, left: 7.0, bottom: 1.0, right: 7.0)
		static let cornerRadius: CGFloat = 8.0

		// macOS 26: no background pill, subtle text
		// macOS 15: traditional background pill with named colors
		static let useTraditionalBadge: Bool = {
			if #available(macOS 26, *) {
				return false
			}
			return true
		}()

		static let backgroundColor: NSColor = {
			if useTraditionalBadge {
				return Assets.Colors.sidebarUnreadCountBackground
			}
			return NSColor.clear
		}()

		static let textSize: CGFloat = {
			if useTraditionalBadge {
				return 11.0
			}
			return 13.0
		}()

		static let textFont: NSFont = {
			if useTraditionalBadge {
				return NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .semibold)
			}
			return NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .regular)
		}()
	}

	var unreadCount = 0 {
		didSet {
			invalidateIntrinsicContentSize()
			needsDisplay = true
		}
	}
	/// Text for the count, or nil when there's nothing to count.
	var unreadCountText: String? {
		unreadCount > 0 ? unreadCount.formatted() : nil
	}

	var isSelected: Bool = false {
		didSet {
			needsDisplay = true
		}
	}

	private var currentTextColor: NSColor {
		if Appearance.useTraditionalBadge {
			return Assets.Colors.sidebarUnreadCountText
		}
		return isSelected ? NSColor.white : NSColor.secondaryLabelColor
	}

	private var textAttributes: [NSAttributedString.Key: AnyObject] {
		return [
			.foregroundColor: currentTextColor,
			.font: Appearance.textFont,
			.kern: NSNull()
		]
	}

	private var intrinsicContentSizeIsValid = false
	private var _intrinsicContentSize = NSSize.zero

	override var intrinsicContentSize: NSSize {
		if !intrinsicContentSizeIsValid {
			var size = NSSize.zero
			if let unreadCountText {
				size = textSize(unreadCountText)
				size.width += (Appearance.padding.left + Appearance.padding.right)
				size.height += (Appearance.padding.top + Appearance.padding.bottom)
			}
			_intrinsicContentSize = size
			intrinsicContentSizeIsValid = true
		}
		return _intrinsicContentSize
	}

	nonisolated override var isFlipped: Bool {
		return true
	}

	override func invalidateIntrinsicContentSize() {
		intrinsicContentSizeIsValid = false
	}

	private static var textSizeCache = [String: NSSize]()

	private func textSize(_ text: String) -> NSSize {
		if let cachedSize = UnreadCountView.textSizeCache[text] {
			return cachedSize
		}

		var size = text.size(withAttributes: textAttributes)
		size.height = ceil(size.height)
		size.width = ceil(size.width)

		UnreadCountView.textSizeCache[text] = size
		return size
	}

	private func textRect(_ text: String) -> NSRect {
		let size = textSize(text)
		var r = NSRect.zero
		r.size = size
		r.origin.x = (bounds.maxX - Appearance.padding.right) - r.size.width
		r.origin.y = Appearance.padding.top
		return r
	}

	override func draw(_ dirtyRect: NSRect) {
		let path = NSBezierPath(roundedRect: bounds, xRadius: Appearance.cornerRadius, yRadius: Appearance.cornerRadius)
		Appearance.backgroundColor.setFill()
		path.fill()

		if let unreadCountText {
			unreadCountText.draw(at: textRect(unreadCountText).origin, withAttributes: textAttributes)
		}
	}
}
