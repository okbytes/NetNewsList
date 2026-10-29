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
			updateAccessibility()
		}
	}

	private let titleLabel = UILabel()
	private let countChip = CountChipView()

	/// Title 3's 20 points plus 4, scaling with Dynamic Type up to Title 3's size at xxxLarge,
	/// so at accessibility sizes it doesn't crowd the "…" button. The Large Content Viewer shows it larger.
	private static let titleFont = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 24, weight: .heavy), maximumPointSize: 31)

	override init(frame: CGRect) {
		super.init(frame: frame)

		titleLabel.font = Self.titleFont
		titleLabel.adjustsFontForContentSizeCategory = true
		titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		countChip.isHidden = true

		let stackView = UIStackView(arrangedSubviews: [titleLabel, countChip])
		stackView.axis = .horizontal
		stackView.alignment = .center
		stackView.spacing = 7
		stackView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stackView)
		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
			stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
			stackView.topAnchor.constraint(equalTo: topAnchor),
			stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])

		isAccessibilityElement = true
		accessibilityTraits = .header
		showsLargeContentViewer = true
		addInteraction(UILargeContentViewerInteraction())
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func updateAccessibility() {
		accessibilityLabel = title
		accessibilityValue = count > 0 ? String(AttributedString(localized: "^[\(count) article](inflect: true)").characters) : nil
		largeContentTitle = count > 0 ? "\(title) \(count.formatted())" : title
	}
}

/// A knocked-out chip: the text is cut out of a gray rounded rectangle, so whatever is behind the bar shows through it.
private final class CountChipView: UIView {

	var text = "" {
		didSet {
			invalidateIntrinsicContentSize()
			setNeedsDisplay()
		}
	}

	private var font: UIFont {
		let font = UIFont.systemFont(ofSize: 13, weight: .heavy)
		let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 13) } ?? font
		return UIFontMetrics(forTextStyle: .title3).scaledFont(for: rounded, maximumPointSize: 17, compatibleWith: traitCollection)
	}

	/// The chip's measurements grow with its font.
	private var scale: CGFloat {
		font.pointSize / 13
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

	override var intrinsicContentSize: CGSize {
		let height = (20 * scale).rounded()
		let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
		return CGSize(width: max(height, ceil(textWidth + 2 * 5 * scale)), height: height)
	}

	override func draw(_ rect: CGRect) {
		guard let context = UIGraphicsGetCurrentContext() else {
			return
		}
		UIColor.secondaryLabel.setFill()
		UIBezierPath(roundedRect: bounds, cornerRadius: 5 * scale).fill()

		context.setBlendMode(.destinationOut)
		let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
		let textSize = (text as NSString).size(withAttributes: attributes)
		let origin = CGPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2)
		(text as NSString).draw(at: origin, withAttributes: attributes)
	}
}
