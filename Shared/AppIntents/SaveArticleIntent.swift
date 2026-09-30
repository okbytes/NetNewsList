//
//  SaveArticleIntent.swift
//  NetNewsList
//
//  “Save to NetNewsList” in Shortcuts, Siri and Spotlight on the Mac and iOS.
//  It runs in the app without opening it. Without a body, the page is extracted
//  the next time the app is in the foreground, on this device or another.
//

import Foundation
import AppIntents

struct SaveArticleIntent: AppIntent {

	static let title: LocalizedStringResource = "Save to NetNewsList"
	static let description = IntentDescription("Saves a web page to your NetNewsList reading list. Pass the page’s text as the body, for example from “Get Article using Safari Reader”, to store it without downloading the page again.")

	static let openAppWhenRun = false

	@Parameter(title: "URL")
	var url: URL

	@Parameter(title: "Title")
	var pageTitle: String?

	@Parameter(title: "Body", inputOptions: String.IntentInputOptions(multiline: true))
	var body: String?

	static var parameterSummary: some ParameterSummary {
		Summary("Save \(\.$url) to NetNewsList") {
			\.$pageTitle
			\.$body
		}
	}

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let article = try await ExtractionCoordinator.shared.saveArticle(url: url.absoluteString, title: pageTitle, body: body)
		let name = article.title ?? url.host() ?? url.absoluteString
		return .result(dialog: "Saved \(name) to NetNewsList.")
	}
}
