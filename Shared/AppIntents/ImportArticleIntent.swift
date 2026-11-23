//
//  ImportArticleIntent.swift
//  NetNewsList
//
//  “Import to NetNewsList” in Shortcuts, Siri and Spotlight on the Mac and iOS.
//  Imports a note, Markdown, HTML, rich text, plain text, or PDF document as a
//  reading-list article without needing a web URL.
//

import Foundation
import AppIntents
import UniformTypeIdentifiers
import Extraction

struct ImportArticleIntent: AppIntent {

	static let title: LocalizedStringResource = "Import to NetNewsList"
	static let description = IntentDescription("Imports a note, Markdown document, rich text, HTML, or PDF into your NetNewsList reading list without needing a web address.")

	static let openAppWhenRun = false

	@Parameter(title: "Title")
	var documentTitle: String?

	@Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
	var text: String?

	@Parameter(title: "File")
	var file: IntentFile?

	static var parameterSummary: some ParameterSummary {
		Summary("Import \(\.$documentTitle) to NetNewsList") {
			\.$text
			\.$file
		}
	}

	@MainActor
	func perform() async throws -> some IntentResult & ProvidesDialog {
		let article: Any
		let name: String

		if let file {
			let saved = try await ExtractionCoordinator.shared.importData(file.data,
																		  contentType: file.type,
																		  fileName: file.filename,
																		  title: documentTitle)
			article = saved
			name = saved.title ?? file.filename
		} else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			let saved = try await ExtractionCoordinator.shared.importText(text, title: documentTitle)
			article = saved
			name = saved.title ?? NSLocalizedString("document", comment: "Shortcuts dialog fallback name")
		} else {
			throw DocumentImportError.emptyDocument
		}

		_ = article
		return .result(dialog: "Imported \(name) into NetNewsList.")
	}
}
