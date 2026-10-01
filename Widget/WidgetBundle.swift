//
//  WidgetBundle.swift
//  NetNewsWire Widget Extension
//
//  Created by Stuart Breckenridge on 18/11/2020.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import WidgetKit
import SwiftUI

// MARK: - Supported Widgets

struct UnreadWidget: Widget {
	let kind: String = "NetNewsList.UnreadWidget"

	var body: some WidgetConfiguration {

		return StaticConfiguration(kind: kind, provider: Provider(), content: { entry in
			UnreadWidgetView(entry: entry)
				.frame(maxHeight: .infinity, alignment: .top)
				.containerBackground(for: .widget) {
					Color.clear
				}
				.clipped()
		})
		.configurationDisplayName(Text("label.text.unread", comment: "Unread"))
		.description(Text("label.text.unread-widget-description", comment: "A description of the Unread widget."))
		.supportedFamilies([.systemMedium, .systemLarge])
	}
}

struct StarredWidget: Widget {
	let kind: String = "NetNewsList.StarredWidget"

	var body: some WidgetConfiguration {

		return StaticConfiguration(kind: kind, provider: Provider(), content: { entry in
			StarredWidgetView(entry: entry)
				.frame(maxHeight: .infinity, alignment: .top)
				.containerBackground(for: .widget) {
					Color.clear
				}
				.clipped()
		})
		.configurationDisplayName(Text("label.text.starred", comment: "Starred"))
		.description(Text("label.text.starred-widget-description", comment: "A description of the Starred widget."))
		.supportedFamilies([.systemMedium, .systemLarge])
	}
}

struct LockScreenSummaryWidget: Widget {
	let kind: String = "NetNewsList.LockScreenSummaryWidget"

	var body: some WidgetConfiguration {

		return StaticConfiguration(kind: kind, provider: Provider(), content: { entry in
			LockScreenSummaryWidgetView(entry: entry)
				.frame(maxHeight: .infinity, alignment: .top)
				.containerBackground(for: .widget) {
					Color.clear
				}
				.clipped()
		})
		.configurationDisplayName(Text("label.text.lock-screen-summary", comment: "Summary"))
		.description(Text("label.text.lock-screen-summary-description", comment: "A description of the Lock Screen Summary widget."))
		.supportedFamilies([.accessoryRectangular])
	}
}

// MARK: - WidgetBundle
@main
struct NetNewsWireWidgets: WidgetBundle {
	@WidgetBundleBuilder
	var body: some Widget {
		UnreadWidget()
		StarredWidget()
		LockScreenSummaryWidget()
	}
}
