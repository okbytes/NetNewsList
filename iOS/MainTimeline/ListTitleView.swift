//
//  ListTitleView.swift
//  NetNewsList
//
//  The list's name at the leading edge of the bar, with the Queue's count in a chip.
//

import UIKit

/// A list's name in heavy type at the leading edge of the bar, with the Queue's count in a chip
/// beside it (after Verbatim's library title and metadata badges).
final class ListTitleView: UIView {

	var title = "" {
		didSet {
			titleLabel.text = title
			updateAccessibility()
		}
	}

	/// Shown in the chip; zero hides it.
	var count = 0 {
		didSet {
			countChip.text = count.formatted()
			countChip.isHidden = count == 0
			titleEndsView.isActive = countChip.isHidden
			chipEndsView.isActive = !countChip.isHidden
			updateAccessibility()
		}
	}

	private let titleLabel = UILabel()
	private let countChip = CountChipView()
	private lazy var titleEndsView = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
	private lazy var chipEndsView = countChip.trailingAnchor.constraint(equalTo: trailingAnchor)
	/// Centers the chip on the title's lowercase letters; set from the title's font in `updateConstraints`.
	private lazy var chipOnXHeight = countChip.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor)

	/// Title 3's 20 points plus 4, scaling with Dynamic Type up to Title 3's size at xxxLarge,
	/// so at accessibility sizes it doesn't crowd the "…" button. The Large Content Viewer shows it larger.
	private static let titleFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 24, weight: .heavy), maximumPointSize: 31)

	override init(frame: CGRect) {
		super.init(frame: frame)

		titleLabel.font = Self.titleFont
		titleLabel.adjustsFontForContentSizeCategory = true
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		addSubview(titleLabel)
		countChip.isHidden = true
		countChip.translatesAutoresizingMaskIntoConstraints = false
		addSubview(countChip)
		// The bar makes this view taller than the title. Stretched with it, the label would center its
		// text in the extra height while its baseline anchor stayed put, and the chip would sit high.
		let fitsTitle = heightAnchor.constraint(equalTo: titleLabel.heightAnchor)
		fitsTitle.priority = .fittingSizeLevel
		NSLayoutConstraint.activate([
			titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
			titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
			titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
			fitsTitle,
			countChip.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
			chipOnXHeight,
			titleEndsView
		])
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
			self.setNeedsUpdateConstraints()
		}

		isAccessibilityElement = true
		accessibilityTraits = .header
		showsLargeContentViewer = true
		addInteraction(UILargeContentViewerInteraction())
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func updateConstraints() {
		chipOnXHeight.constant = -titleLabel.font.xHeight / 2
		super.updateConstraints()
	}

	private func updateAccessibility() {
		accessibilityLabel = title
		accessibilityValue = count > 0 ? String(AttributedString(localized: "^[\(count) article](inflect: true)").characters) : nil
		largeContentTitle = count > 0 ? "\(title) \(count.formatted())" : title
	}
}

/// A knocked-out chip: the count is cut out of a rounded rectangle in the title's color, so whatever is behind the bar
/// shows through it.
private final class CountChipView: UIView {

	var text = "" {
		didSet {
			invalidateIntrinsicContentSize()
			setNeedsDisplay()
		}
	}

	/// 11 points at the default text size, scaling like Title 3.
	private var font: UIFont {
		let bold = UIFont.systemFont(ofSize: 11, weight: .bold)
		let rounded = bold.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 11) } ?? bold
		return UIFontMetrics(forTextStyle: .title3).scaledFont(for: rounded, maximumPointSize: 15, compatibleWith: traitCollection)
	}

	/// The chip's padding and corners grow with its font.
	private var scale: CGFloat {
		font.pointSize / 11
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = false
		backgroundColor = .clear
		contentMode = .redraw
		setContentCompressionResistancePriority(.required, for: .horizontal)
		registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (self: Self, _) in
			self.invalidateIntrinsicContentSize()
			self.setNeedsDisplay()
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	/// 4 points around the digits (which are cap height), and at least as wide as it is tall.
	override var intrinsicContentSize: CGSize {
		let font = font
		let height = (font.capHeight + 2 * 4 * scale).rounded()
		let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
		return CGSize(width: max(height, ceil(textWidth + 2 * 4 * scale)), height: height)
	}

	override func draw(_ rect: CGRect) {
		guard let context = UIGraphicsGetCurrentContext() else {
			return
		}
		// The title's color.
		UIColor.label.setFill()
		UIBezierPath(roundedRect: bounds, cornerRadius: 4 * scale).fill()

		context.setBlendMode(.destinationOut)
		let font = font
		let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
		let textWidth = (text as NSString).size(withAttributes: attributes).width
		// The digits centered top to bottom: their baseline is half a cap height below the middle.
		let baseline = (bounds.height + font.capHeight) / 2
		(text as NSString).draw(at: CGPoint(x: (bounds.width - textWidth) / 2, y: baseline - font.ascender), withAttributes: attributes)
	}
}
