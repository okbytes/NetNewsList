//
//  LockScreenSummaryWidgetView.swift
//  NetNewsWire iOS Widget Extension
//
//  Created by Stuart Breckenridge on 08/01/2026.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import SwiftUI
import WidgetKit

struct LockScreenSummaryWidgetView: View {

	var entry: Provider.Entry

    var body: some View {
		HStack(alignment: .center) {
			queueImage
			Text("label.text.queue", comment: "Queue")
			Spacer()
			Text(verbatim: entry.widgetData.queueCount.formatted())
				.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.font(.subheadline)
    }

	var queueImage: some View {
		Image(systemName: "tray.fill")
			.resizable()
			.scaledToFit()
			.frame(width: 14, height: 14)
	}

}
