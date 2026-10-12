//
//  ArticleTheme.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 9/26/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import Foundation

/// The article stylesheet and template. There is one theme, the built-in default.
struct ArticleTheme: Sendable {

	static let defaultTheme = ArticleTheme()

	let template: String
	let css: String

	private init() {
		css = Self.bundledText("core", "css") + "\n" + Self.bundledText("stylesheet", "css")
		template = Self.bundledText("template", "html")
	}

	private static func bundledText(_ name: String, _ type: String) -> String {
		guard let path = Bundle.main.path(forResource: name, ofType: type),
			  let text = try? String(contentsOfFile: path, encoding: .utf8) else {
			preconditionFailure("\(name).\(type) is missing from the app bundle.")
		}
		return text
	}
}
