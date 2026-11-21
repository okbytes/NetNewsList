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

	var id: String { description() }

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

	func description() -> String {
		switch self {
		case .small:
			return NSLocalizedString("Small", comment: "Small")
		case .medium:
			return NSLocalizedString("Medium", comment: "Medium")
		case .large:
			return NSLocalizedString("Large", comment: "Large")
		case .xlarge:
			return NSLocalizedString("Extra Large", comment: "X-Large")
		case .xxlarge:
			return NSLocalizedString("Extra Extra Large", comment: "XX-Large")
		}
	}

}

struct ArticleTextSizePicker: View {
	@AppStorage(ArticleTextSize.key) private var size = ArticleTextSize.large.rawValue

	var body: some View {
		Picker("Article text size", selection: $size) {
			ForEach(ArticleTextSize.allCases) { size in
				Text(size.description()).tag(size.rawValue)
			}
		}
		.onChange(of: size) {
			NotificationCenter.default.post(name: ArticleTextSize.didChange, object: nil)
		}
	}
}
