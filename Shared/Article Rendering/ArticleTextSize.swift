//
//  ArticleTextSize.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 11/3/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import SwiftUI
import WebKit

enum ArticleTextSize: Int, CaseIterable, Identifiable {
	case small = 1
	case medium = 2
	case large = 3
	case xlarge = 4
	case xxlarge = 5

	static let key = "articleReadingTextSize"
	static let didChange = Notification.Name("ArticleReadingTextSizeDidChange")

	static var current: Self {
		Self(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .large
	}

	@MainActor static func apply(to webView: WKWebView?) {
		webView?.evaluateJavaScript("document.getElementById('bodyContainer')?.setAttribute('class', 'articleBody \(current.cssClass)')", completionHandler: nil)
	}

	var id: Int { rawValue }

	// The stylesheet uses two-point steps around the medium body size.
	func label(relativeTo medium: CGFloat) -> String {
		let points = medium + CGFloat(2 * (rawValue - Self.medium.rawValue))
		return "\(points.formatted()) pt"
	}

	var cssClass: String {
		switch self {
		case .small:
			return "smallText"
		case .medium:
			return "mediumText"
		case .large:
			return "largeText"
		case .xlarge:
			return "xlargeText"
		case .xxlarge:
			return "xxlargeText"
		}
	}
}

#if os(iOS)
struct ArticleTextSizePicker: View {
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize

	private var medium: CGFloat {
		let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
		return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
	}
	@AppStorage(ArticleTextSize.key) private var size = ArticleTextSize.large.rawValue

	var body: some View {
		Picker("Article text size", selection: $size) {
			ForEach(ArticleTextSize.allCases) { size in
				Text(size.label(relativeTo: medium)).tag(size.rawValue)
			}
		}
		.onChange(of: size) {
			NotificationCenter.default.post(name: ArticleTextSize.didChange, object: nil)
		}
	}
}
#endif
