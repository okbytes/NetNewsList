//
//  MainWindowState.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 12/16/23.
//  Copyright © 2023 Ranchero Software. All rights reserved.
//

import Foundation

final class MainWindowState: NSObject, NSSecureCoding {

	static let supportsSecureCoding = true

	let isFullScreen: Bool
	/// The list’s width. Zero when never saved.
	let timelineWidth: Int
	let timelineWindowState: TimelineWindowState?
	let detailWindowState: DetailWindowState?

	// State saved before the sidebar was removed also has splitViewWidths, columnLayoutTimelineHeight,
	// isSidebarHidden and sidebarWindowState, which are ignored.
	init(isFullScreen: Bool, timelineWidth: Int, timelineWindowState: TimelineWindowState? = nil, detailWindowState: DetailWindowState? = nil) {
		self.isFullScreen = isFullScreen
		self.timelineWidth = timelineWidth
		self.timelineWindowState = timelineWindowState
		self.detailWindowState = detailWindowState
	}

	private struct Key {
		static let isFullScreen = "isFullScreen"
		static let timelineWidth = "timelineWidth"
		static let timelineWindowState = "timelineWindowState"
		static let detailWindowState = "detailWindowState"
	}

	required init?(coder: NSCoder) {
		isFullScreen = coder.decodeBool(forKey: Key.isFullScreen)
		timelineWidth = coder.decodeInteger(forKey: Key.timelineWidth)
		timelineWindowState = coder.decodeObject(of: TimelineWindowState.self, forKey: Key.timelineWindowState)
		detailWindowState = coder.decodeObject(of: DetailWindowState.self, forKey: Key.detailWindowState)
	}

	func encode(with coder: NSCoder) {
		coder.encode(isFullScreen, forKey: Key.isFullScreen)
		coder.encode(timelineWidth, forKey: Key.timelineWidth)
		coder.encode(timelineWindowState, forKey: Key.timelineWindowState)
		coder.encode(detailWindowState, forKey: Key.detailWindowState)
	}

	override var description: String {
		let timeline = timelineWindowState?.description ?? "nil"
		let detail = detailWindowState?.description ?? "nil"
		return "MainWindowState: fullScreen=\(isFullScreen), timelineWidth=\(timelineWidth), timeline=[\(timeline)], detail=[\(detail)]"
	}
}
