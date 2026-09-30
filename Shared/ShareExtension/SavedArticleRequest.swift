//
//  SavedArticleRequest.swift
//  NetNewsList
//
//  A page to save, handed from a share extension to the app. Extensions can’t
//  use iCloud or run extraction, so they only write requests; the app saves them.
//  See Technotes/NetNewsList/Plan.md, D4.
//

import Foundation

struct SavedArticleRequest: Codable, Sendable, Equatable {

	let url: String
	let title: String?

	/// Readable HTML captured by the sender, when it has some. The app stores it
	/// instead of fetching the page.
	let body: String?
	let dateRequested: Date

	init(url: String, title: String?, body: String? = nil, dateRequested: Date = Date()) {
		self.url = url
		self.title = title
		self.body = body
		self.dateRequested = dateRequested
	}
}
