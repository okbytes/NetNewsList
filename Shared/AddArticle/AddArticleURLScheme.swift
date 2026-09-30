//
//  AddArticleURLScheme.swift
//  NetNewsList
//
//  netnewslist://add?url={page}&title={optional title}
//  Used by the browser extension’s local mode, Shortcuts and anything else that
//  can open a URL.
//

import Foundation

enum AddArticleURLScheme {

	static func request(from url: URL) -> SavedArticleRequest? {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			  components.scheme?.lowercased() == "netnewslist",
			  components.host?.lowercased() == "add",
			  let queryItems = components.queryItems,
			  let pageURL = queryItems.first(where: { $0.name == "url" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !pageURL.isEmpty else {
			return nil
		}
		let title = queryItems.first(where: { $0.name == "title" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
		return SavedArticleRequest(url: pageURL, title: (title?.isEmpty ?? true) ? nil : title)
	}
}
