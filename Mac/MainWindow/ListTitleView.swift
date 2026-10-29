//
//  ListTitleView.swift
//  NetNewsList
//
//  The list's name at the leading edge of the toolbar, with the Queue's count in a chip,
//  like the iPhone's. Clicking it switches between the Queue and the Archive.
//

import AppKit

final class ListTitleView: NSView {

	var title = "" {
		didSet {
			titleField.stringValue = title
			setAccessibilityLabel(title)
		}
	}

	/// Shown in the chip; zero hides it.
	var count = 0 {
		didSet {
			countChip.text = count.formatted()
			countChip.isHidden = count == 0
			titleEndsView.isActive = countChip.isHidden
			chipEndsView.isActive = !countChip.isHidden
			setAccessibilityValue(count > 0 ? String(AttributedString(localized: "^[\(count) article](inflect: true)").characters) : nil)
		}
	}

	/// Called when the title is clicked.
	var action: (() -> Void)?

	private let titleField = NSTextField(labelWithString: "")
	private let countChip = CountChipView()
	private lazy var titleEndsView = titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
	private lazy var chipEndsView = countChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)

		titleField.font = .systemFont(ofSize: 17, weight: .bold)
		titleField.textColor = .labelColor
		titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
		// The whole title is one button to VoiceOver.
		titleField.setAccessibilityElement(false)
		titleField.translatesAutoresizingMaskIntoConstraints = false
		addSubview(titleField)
		countChip.isHidden = true
		countChip.translatesAutoresizingMaskIntoConstraints = false
		addSubview(countChip)
		NSLayoutConstraint.activate([
			titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			titleField.topAnchor.constraint(equalTo: topAnchor),
			titleField.bottomAnchor.constraint(equalTo: bottomAnchor),
			countChip.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
			// Centered on the title's lowercase letters.
			countChip.centerYAnchor.constraint(equalTo: titleField.firstBaselineAnchor, constant: -(titleField.font?.xHeight ?? 0) / 2),
			titleEndsView
		])

		setAccessibilityElement(true)
		setAccessibilityRole(.button)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// MARK: - Clicks

	// In the title bar a click would otherwise start moving the window.
	override var mouseDownCanMoveWindow: Bool {
		false
	}

	// Like the toolbar's buttons, it works on the click that brings the window forward.
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		true
	}

	// Clicks on the title's text or the chip are clicks on the whole title.
	override func hitTest(_ point: NSPoint) -> NSView? {
		frame.contains(point) ? self : nil
	}

	override func mouseDown(with event: NSEvent) {
		alphaValue = 0.6
	}

	override func mouseUp(with event: NSEvent) {
		alphaValue = 1
		if bounds.contains(convert(event.locationInWindow, from: nil)) {
			action?()
		}
	}

	override func accessibilityPerformPress() -> Bool {
		action?()
		return true
	}
}

/// A knocked-out chip: the text is cut out of a rounded rectangle in the title's color, so the toolbar shows through it.
private final class CountChipView: NSView {

	var text = "" {
		didSet {
			invalidateIntrinsicContentSize()
			needsDisplay = true
		}
	}

	private static let font: NSFont = {
		let font = NSFont.systemFont(ofSize: 8, weight: .bold)
		return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 8) } ?? font
	}()

	/// Around the digits, and the corners' radius. The chip, its type and its padding are the iPhone's scaled to the smaller title.
	private static let padding = 2.75

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		// Its own layer, so cutting out the text clears only the chip's pixels.
		wantsLayer = true
		layerContentsRedrawPolicy = .onSetNeedsDisplay
		// The title dims while the window isn't the main window, and the chip with it.
		NotificationCenter.default.addObserver(self, selector: #selector(mainWindowDidChange(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(mainWindowDidChange(_:)), name: NSWindow.didResignMainNotification, object: nil)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var isFlipped: Bool {
		true
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	@objc private func mainWindowDidChange(_ notification: Notification) {
		if notification.object as? NSWindow === window {
			needsDisplay = true
		}
	}

	/// The padding around the digits (which are cap height), and at least as wide as it is tall.
	override var intrinsicContentSize: NSSize {
		let height = (Self.font.capHeight + 2 * Self.padding).rounded()
		let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
		return NSSize(width: max(height, ceil(textWidth + 2 * Self.padding)), height: height)
	}

	override func draw(_ dirtyRect: NSRect) {
		guard let context = NSGraphicsContext.current?.cgContext else {
			return
		}
		// The title's color: in a window that isn't main, AppKit dims the title to about tertiary label color.
		(window?.isMainWindow == true ? NSColor.labelColor : NSColor.tertiaryLabelColor).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: Self.padding, yRadius: Self.padding).fill()

		context.setBlendMode(.destinationOut)
		let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.black]
		// The digits' ink centered in the chip.
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
		context.textMatrix = .identity
		let ink = CTLineGetImageBounds(line, context)
		// Upright text in this flipped view.
		context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
		// The baseline goes on a whole device pixel: Core Graphics moves glyphs onto one vertically,
		// which otherwise set the digits a pixel low.
		let baseline = convertToBacking(NSPoint(x: 0, y: bounds.height / 2 + ink.midY)).y.rounded()
		context.textPosition = CGPoint(x: (bounds.width - ink.width) / 2 - ink.minX, y: convertFromBacking(NSPoint(x: 0, y: baseline)).y)
		CTLineDraw(line, context)
	}
}
