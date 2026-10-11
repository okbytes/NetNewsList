//
//  MainFeedCollectionViewCell.swift
//  NetNewsWire-iOS
//
//  Created by Stuart Breckenridge on 23/06/2025.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import UIKit
import RSCore
import Account
import RSTree
import Images

final class MainFeedCollectionViewCell: UICollectionViewCell {
	@IBOutlet var feedTitle: UILabel!
	@IBOutlet var faviconView: IconView!
	@IBOutlet var unreadCountLabel: UILabel!
	private var faviconLeadingConstraint: NSLayoutConstraint?

	var iconImage: IconImage? {
		didSet {
			faviconView.iconImage = iconImage
			faviconView.tintColor = iconImage?.preferredColor ?? Assets.Colors.secondaryAccent
		}
	}

	/// The number of articles in the list. Only the Queue has one; nothing shows at 0.
	var unreadCount: Int = 0 {
		didSet {
			unreadCountLabel.isHidden = unreadCount == 0
			unreadCountLabel.text = unreadCount > 0 ? unreadCount.formatted() : nil
			setNeedsUpdateConfiguration()
		}
	}

	override var accessibilityLabel: String? {
		get {
			let name = feedTitle.text ?? ""
			guard unreadCount > 0 else {
				return name
			}
			return "\(name), \(unreadCount.formatted())"
		}
		set {}
	}

    override func awakeFromNib() {
		MainActor.assumeIsolated {
			super.awakeFromNib()
			isAccessibilityElement = true
			feedTitle.isAccessibilityElement = false
			unreadCountLabel.isAccessibilityElement = false
			faviconView.isAccessibilityElement = false
			// On the storyboard, no leading constraint is set.
			faviconLeadingConstraint = faviconView.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 16)
			faviconLeadingConstraint?.isActive = true
		}
    }

	override func updateConfiguration(using state: UICellConfigurationState) {
		var backgroundConfig: UIBackgroundConfiguration
		if #available(iOS 18, *) {
			backgroundConfig = UIBackgroundConfiguration.listCell().updated(for: state)
		} else if traitCollection.userInterfaceIdiom == .pad {
			backgroundConfig = UIBackgroundConfiguration.listSidebarCell().updated(for: state)
		} else {
			backgroundConfig = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
		}

		// Matches the timeline: accent background and white text when the feeds list is first responder,
		// and no highlight while a row is pressed, so the row goes straight to the selected style.
		let isExpanded = isInExpandedSplitView
		let isActiveSelection = state.isSelected && isExpanded && enclosingViewController?.isFirstResponder == true
		let isHighlighted = state.isHighlighted && !isExpanded
		if state.isHighlighted && !state.isSelected && isExpanded {
			backgroundConfig.backgroundColor = .clear
		}

		switch (isHighlighted || state.isSelected || state.isFocused, traitCollection.userInterfaceIdiom) {
		case _ where isActiveSelection:
			backgroundConfig.backgroundColor = Assets.Colors.primaryAccent
			feedTitle.textColor = .white
			feedTitle.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
			unreadCountLabel.textColor = .white
			unreadCountLabel.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
			faviconView.tintColor = .white
		case (true, .pad):
			backgroundConfig.backgroundColor = .tertiarySystemFill
			feedTitle.textColor = Assets.Colors.primaryAccent
			feedTitle.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
											   weight: .semibold)
			unreadCountLabel.textColor = Assets.Colors.primaryAccent
			unreadCountLabel.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
			faviconView.tintColor = iconImage?.preferredColor ?? Assets.Colors.secondaryAccent
		default:
			feedTitle.textColor = .label
			feedTitle.font = UIFont.preferredFont(forTextStyle: .body)
			unreadCountLabel.font = UIFont.preferredFont(forTextStyle: .body)
			unreadCountLabel.textColor = .secondaryLabel
			faviconView.tintColor = iconImage?.preferredColor ?? Assets.Colors.secondaryAccent
		}
		self.backgroundConfiguration = backgroundConfig
	}
}
