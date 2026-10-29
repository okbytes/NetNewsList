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
			setAccessibilityValue(count > 0 ? String(AttributedString(localized: "^[\(count) article](inflect: true)").characters) : nil)
		}
	}

	/// Called when the title is clicked.
	var action: (() -> Void)?

	private let titleField = NSTextField(labelWithString: "")
	private let countChip = CountChipView()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)

		titleField.font = .systemFont(ofSize: 17, weight: .heavy)
		titleField.textColor = .labelColor
		titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
		// The whole title is one button to VoiceOver.
		titleField.setAccessibilityElement(false)
		countChip.isHidden = true

		let stackView = NSStackView(views: [titleField, countChip])
		stackView.orientation = .horizontal
		stackView.alignment = .centerY
		stackView.spacing = 6
		stackView.detachesHiddenViews = true
		stackView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stackView)
		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
			stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
			stackView.topAnchor.constraint(equalTo: topAnchor),
			stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
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

/// A knocked-out chip: the text is cut out of a gray rounded rectangle, so the toolbar shows through it.
private final class CountChipView: NSView {

	var text = "" {
		didSet {
			invalidateIntrinsicContentSize()
			needsDisplay = true
		}
	}

	private static let font: NSFont = {
		let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
		return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? font
	}()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		// Its own layer, so cutting out the text clears only the chip's pixels.
		wantsLayer = true
		layerContentsRedrawPolicy = .onSetNeedsDisplay
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

	override var intrinsicContentSize: NSSize {
		let height: CGFloat = 17
		let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
		return NSSize(width: max(height, ceil(textWidth + 2 * 4.5)), height: height)
	}

	override func draw(_ dirtyRect: NSRect) {
		guard let context = NSGraphicsContext.current?.cgContext else {
			return
		}
		NSColor.secondaryLabelColor.setFill()
		NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

		context.setBlendMode(.destinationOut)
		let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.black]
		let textSize = (text as NSString).size(withAttributes: attributes)
		let origin = NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2)
		(text as NSString).draw(at: origin, withAttributes: attributes)
	}
}
