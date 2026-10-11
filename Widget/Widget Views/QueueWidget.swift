//
//  QueueWidget.swift
//  NetNewsWire Widget Extension
//
//  Created by Stuart Breckenridge on 18/11/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import WidgetKit
import SwiftUI

struct QueueWidgetView: View {
	@Environment(\.widgetFamily) var family: WidgetFamily
	@Environment(\.sizeCategory) var sizeCategory: ContentSizeCategory

	var entry: Provider.Entry

	var body: some View {
		if entry.widgetData.queueCount == 0 {
			emptyQueue
				.widgetURL(WidgetDeepLink.queue.url)
		} else {
			VStack {
				HStack(alignment: .center) {
					queueImage
						.layoutPriority(1)
					Text("label.text.queue", comment: "Queue")
						.font(.caption2)
						.bold()
						.lineLimit(1)
						.minimumScaleFactor(0.8)
						.fixedSize(horizontal: false, vertical: true)
						.layoutPriority(1)
					Spacer()
						.layoutPriority(0)
					if entry.widgetData.queueCount - maxCount() > 0 {
						Text(verbatim: entry.widgetData.queueCount.formatted())
							.font(.caption2)
							.bold()
							.foregroundColor(.secondary)
							.lineLimit(1)
							.minimumScaleFactor(0.8)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				.widgetURL(WidgetDeepLink.queue.url)
				Divider()
				ForEach(entry.widgetData.queueArticles.prefix(maxCount())) { article in
					ArticleItemView(article: article,
									deepLink: WidgetDeepLink.queueArticle(id: article.id).url)
				}
				Spacer()
			}
			.padding(.vertical, 2)
		}
	}

	var queueImage: some View {
		Image(systemName: "tray.fill")
			.resizable()
			.scaledToFit()
			.frame(width: WidgetLayout.titleImageSize, height: WidgetLayout.titleImageSize, alignment: .top)
			.foregroundColor(.accentColor)
	}

	func maxCount() -> Int {
		var reduceAccessibilityCount: Int = 0
		if SizeCategories().isSizeCategoryLarge(category: sizeCategory) {
			reduceAccessibilityCount = 1
		}

		if family == .systemLarge {
			return entry.widgetData.queueCount >= 7 ? (7 - reduceAccessibilityCount) : entry.widgetData.queueCount
		}
		return entry.widgetData.queueCount >= 3 ? (3 - reduceAccessibilityCount) : entry.widgetData.queueCount
	}

	var emptyQueue: some View {
		VStack(alignment: .center) {
			Spacer()
			Image(systemName: "tray.fill")
				.resizable()
				.scaledToFit()
				.foregroundColor(.accentColor)
				.frame(width: 30)

			Text("label.text.queue", comment: "Queue")
				.font(.headline)
				.foregroundColor(.primary)

			Text("label.text.queue-empty", comment: "The Queue has no articles.")
				.font(.caption)
				.foregroundColor(.gray)
			Spacer()
		}
		.multilineTextAlignment(.center)
		.padding()
	}
}
