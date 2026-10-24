//
//  WidgetDataDecoder.swift
//  NetNewsWire
//
//  Created by Stuart Breckenridge on 18/11/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation

struct WidgetDataDecoder {

	static func decodeWidgetData() throws -> WidgetData {
		// An unsigned build (the simulator, tests) has no app group container.
		guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String,
			  let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
			return WidgetData(queueCount: 0, queueArticles: [], lastUpdateTime: Date())
		}
		let dataURL = containerURL.appendingPathComponent("widget-data.json")
		guard FileManager.default.fileExists(atPath: dataURL.path) else {
			return WidgetData(queueCount: 0, queueArticles: [], lastUpdateTime: Date())
		}
		return try JSONDecoder().decode(WidgetData.self, from: Data(contentsOf: dataURL))
	}

	static func sampleData() -> WidgetData {
		guard let pathToSample = Bundle.main.url(forResource: "widget-sample", withExtension: "json") else {
			return WidgetData(queueCount: 0, queueArticles: [], lastUpdateTime: Date())
		}
		do {
			let data = try Data(contentsOf: pathToSample)
			let decoded = try JSONDecoder().decode(WidgetData.self, from: data)
			return decoded
		} catch {
			return WidgetData(queueCount: 0, queueArticles: [], lastUpdateTime: Date())
		}
	}

}
