//
//  MainTimelineCell.swift
//  NetNewsWire-iOS
//
//  Created by Brent Simmons on 6/22/26.
//

import UIKit
import RSCore
import Images

///  Manual-layout timeline cell modeled on the Mac timeline
///  and the pre-7.0 iOS table view cell.
final class MainTimelineCell: UICollectionViewCell {

	static let reuseIdentifier = "MainTimelineCell"

	var isPreview = false

	private let titleView = MainTimelineCell.multiLineLabel()
	private let summaryView = MainTimelineCell.multiLineLabel()
	private let dateView = MainTimelineCell.singleLineLabel()
	private let feedNameView = MainTimelineCell.singleLineLabel()
	private lazy var iconView = IconView()
	private let topSeparator = UIView()

	var cellData: MainTimelineCellData! {
		didSet {
			updateSubviews()
		}
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		commonInit()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		commonInit()
	}

	override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
		guard layoutAttributes.frame.width > 0 else {
			return layoutAttributes
		}
		let layout = updatedLayout(width: layoutAttributes.frame.width)
		layoutAttributes.frame.size.height = layout.height
		return layoutAttributes
	}

	override func layoutSubviews() {
		super.layoutSubviews()

		let layout = updatedLayout(width: contentView.bounds.width)

		setFrame(for: titleView, rect: layout.titleRect)
		setFrame(for: summaryView, rect: layout.summaryRect)
		feedNameView.setFrameIfNotEqual(layout.feedNameRect)
		dateView.setFrameIfNotEqual(layout.dateRect)
		iconView.setFrameIfNotEqual(layout.iconImageRect)
		topSeparator.frame = CGRect(x: layout.separatorRect.minX, y: 0, width: layout.separatorRect.width, height: 1.0 / traitCollection.displayScale)
	}

	override func updateConfiguration(using state: UICellConfigurationState) {
		super.updateConfiguration(using: state)

		var backgroundConfig: UIBackgroundConfiguration
		if #available(iOS 18, *) {
			backgroundConfig = UIBackgroundConfiguration.listCell().updated(for: state)
		} else {
			backgroundConfig = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
		}
		// The Settings timeline preview isn't in the split view hierarchy, so style it
		// the way the timeline usually looks on the device.
		let usesExpandedStyle = isPreview ? UIDevice.current.userInterfaceIdiom == .pad : isInExpandedSplitView
		if !usesExpandedStyle {
			// Full-bleed rectangle selection when the timeline has the screen to itself.
			// When the split view is expanded — iPad, or a large iPhone in landscape —
			// it gets the rounded, inset selection below.
			backgroundConfig.cornerRadius = 0
			backgroundConfig.backgroundInsets = .zero
			backgroundConfig.edgesAddingLayoutMarginsToBackgroundInsets = []
		} else if #available(iOS 26, *) {
			backgroundConfig.cornerRadius = 20
			backgroundConfig.edgesAddingLayoutMarginsToBackgroundInsets = [.leading, .trailing]
			if UIDevice.current.userInterfaceIdiom == .pad {
				backgroundConfig.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: -8, bottom: 0, trailing: -8)
			} else if isPreview {
				backgroundConfig.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: -16, bottom: 0, trailing: -16)
			} else {
				backgroundConfig.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: -12, bottom: 0, trailing: -12)
			}
		} else {
			backgroundConfig.cornerRadius = 0
		}

		// Matches the feeds list: accent background when the timeline is first responder, gray otherwise.
		let isActiveSelection = state.isSelected && isInExpandedSplitView && enclosingViewController?.isFirstResponder == true

		if state.isSwiped {
			backgroundConfig.backgroundColor = .secondarySystemFill
		} else if state.isSelected {
			// When collapsed, keep the standard system selection color from updated(for: state).
			if isInExpandedSplitView {
				backgroundConfig.backgroundColor = isActiveSelection ? Assets.Colors.primaryAccent : .tertiarySystemFill
			}
		} else {
			backgroundConfig.backgroundColor = .clear
		}

		let isActive = state.isSwiped || state.isSelected

		if isPreview {
			backgroundConfig.backgroundColor = traitCollection.userInterfaceStyle == .dark ? .secondarySystemBackground : .white
		}
		backgroundConfiguration = backgroundConfig

		topSeparator.alpha = (isActive || isPreview) ? 0.0 : 1.0

		// Text goes white only on the accent background. On gray, labels keep their normal colors.
		updateColors(active: isActiveSelection)
	}

	func setIconImage(_ image: IconImage) {
		iconView.iconImage = image
	}
}

// MARK: - Private

private extension MainTimelineCell {

	static func singleLineLabel() -> UILabel {
		let label = NonIntrinsicLabel()
		label.lineBreakMode = .byTruncatingTail
		label.allowsDefaultTighteningForTruncation = false
		label.adjustsFontForContentSizeCategory = true
		return label
	}

	static func multiLineLabel() -> UILabel {
		let label = NonIntrinsicLabel()
		label.numberOfLines = 0
		label.lineBreakMode = .byTruncatingTail
		label.allowsDefaultTighteningForTruncation = false
		label.adjustsFontForContentSizeCategory = true
		return label
	}

	func commonInit() {
		isAccessibilityElement = true
		topSeparator.backgroundColor = .separator.withAlphaComponent(0.1)
		for view in [titleView, summaryView, dateView, feedNameView, iconView, topSeparator] {
			contentView.addSubview(view)
			view.isAccessibilityElement = false
		}
	}

	func updatedLayout(width: CGFloat) -> MainTimelineCellLayout {
		guard cellData != nil else {
			return MainTimelineDefaultCellLayout(width: width, insets: .zero, cellData: MainTimelineCellData())
		}
		if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
			return MainTimelineAccessibilityCellLayout(width: width, insets: .zero, cellData: cellData)
		}
		return MainTimelineDefaultCellLayout(width: width, insets: .zero, cellData: cellData)
	}

	func setFrame(for label: UILabel, rect: CGRect) {
		if Int(floor(rect.height)) == 0 || Int(floor(rect.width)) == 0 {
			label.isHidden = true
		} else {
			label.isHidden = false
			label.setFrameIfNotEqual(rect)
		}
	}

	func updateSubviews() {
		titleView.font = MainTimelineDefaultCellLayout.titleFont
		titleView.attributedText = cellData.attributedTitle.applyingBaseFont(MainTimelineDefaultCellLayout.titleFont)

		summaryView.font = MainTimelineDefaultCellLayout.summaryFont
		summaryView.text = cellData.summary

		dateView.font = MainTimelineDefaultCellLayout.dateFont
		dateView.text = cellData.dateString

		switch cellData.showFeedName {
		case .feed:
			feedNameView.font = MainTimelineDefaultCellLayout.feedNameFont
			feedNameView.text = cellData.feedName
			feedNameView.isHidden = false
		case .byline:
			feedNameView.font = MainTimelineDefaultCellLayout.feedNameFont
			feedNameView.text = cellData.byline
			feedNameView.isHidden = false
		case .none:
			feedNameView.isHidden = true
		}

		if cellData.showIcon, let iconImage = cellData.iconImage {
			iconView.iconImage = iconImage
			iconView.isHidden = false
		} else {
			iconView.iconImage = nil
			iconView.isHidden = true
		}

		updateColors(active: configurationState.isSelected && isInExpandedSplitView)
		updateAccessibilityLabel()
		setNeedsLayout()
	}

	func updateColors(active: Bool) {
		titleView.textColor = active ? .white : .label
		summaryView.textColor = active ? .white : (cellData.title.isEmpty ? .label : .secondaryLabel)
		dateView.textColor = active ? .white : .secondaryLabel
		feedNameView.textColor = active ? .white : .secondaryLabel
	}

	func updateAccessibilityLabel() {
		accessibilityLabel = "\(cellData.feedName), \(cellData.title), \(cellData.summary), \(cellData.dateString)"
	}
}
