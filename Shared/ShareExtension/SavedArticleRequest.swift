//
//  SavedArticleRequest.swift
//  NetNewsList
//
//  A page or imported document handed from a share extension to the app.
//  Extensions can’t use iCloud or run extraction, so they only write requests;
//  the app saves or imports them. See Technotes/NetNewsList/Plan.md, D4.
//

import Foundation

struct SavedArticleRequest: Codable, Sendable, Equatable {

	/// The web page URL, or nil for an imported document without a source link.
	let url: String?
	let title: String?

	/// Readable HTML captured by the sender (SafariExt.js), or text/HTML of a shared note.
	let body: String?

	/// Relative file name inside `SavedArticleInbox.attachmentsDirectoryURL` for a shared file
	/// (such as a PDF, RTF, RTFD, Markdown, or HTML file).
	let importedFileName: String?

	/// UTType identifier describing `body` or `importedFileName`.
	let contentTypeIdentifier: String?

	let dateRequested: Date

	init(url: String?, title: String?, body: String? = nil, importedFileName: String? = nil, contentTypeIdentifier: String? = nil, dateRequested: Date = Date()) {
		self.url = url
		self.title = title
		self.body = body
		self.importedFileName = importedFileName
		self.contentTypeIdentifier = contentTypeIdentifier
		self.dateRequested = dateRequested
	}
}
