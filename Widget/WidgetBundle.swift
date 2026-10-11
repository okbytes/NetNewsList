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

struct QueueWidget: Widget {
	let kind: String = WidgetKind.queue

	var body: some WidgetConfiguration {

		return StaticConfiguration(kind: kind, provider: Provider(), content: { entry in
			QueueWidgetView(entry: entry)
				.frame(maxHeight: .infinity, alignment: .top)
				.containerBackground(for: .widget) {
					Color.clear
				}
				.clipped()
		})
		.configurationDisplayName(Text("label.text.queue", comment: "Queue"))
		.description(Text("label.text.queue-widget-description", comment: "A description of the Queue widget."))
		.supportedFamilies([.systemMedium, .systemLarge])
	}
}

struct LockScreenSummaryWidget: Widget {
	let kind: String = WidgetKind.lockScreenSummary

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
		QueueWidget()
		LockScreenSummaryWidget()
	}
}
