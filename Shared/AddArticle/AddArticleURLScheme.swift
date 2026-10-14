//
//  AddArticleURLScheme.swift
//  NetNewsList
//
//  netnewslist://add?url={page}&title={optional title}
//  Used by Shortcuts and anything else that can open a URL. The Mac Debug build, NetNewsList Dev, registers netnewslist-dev
//  instead, so these links reach the installed app.
//

import Foundation

enum AddArticleURLScheme {

	private static let schemes: Set<String> = ["netnewslist", "netnewslist-dev"]

	static func request(from url: URL) -> SavedArticleRequest? {
		guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			  let scheme = components.scheme?.lowercased(),
			  schemes.contains(scheme),
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
