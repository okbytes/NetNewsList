//
//  URLCanonicalizer.swift
//  Account
//
//  One page, one article: two devices saving the same page must compute the same
//  article ID, so every saved URL is reduced to a canonical form first.
//
//  The rules are checked against the vectors in
//  Tests/AccountTests/Resources/url-canonicalization.json.
//

import Foundation

public enum URLCanonicalizer {

	/// Query items that only track where a click came from.
	private static let trackingQueryItemNames: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"]

	/// Hosts that serve X posts, including the mirrors people share for their link previews.
	private static let xHosts: Set<String> = ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com", "fixvx.com"]

	/// Returns the canonical form of an http or https URL, or nil for anything else.
	///
	/// Rules, applied in order: lowercase the scheme and host; drop the default port;
	/// an X post on any X host becomes `https://x.com/i/status/<id>`; drop the fragment;
	/// drop `utm_*` and other tracking query items, keeping the rest exactly as written
	/// and in their original order; an empty path becomes `/`; any other path loses one
	/// trailing slash.
	public static func canonicalString(for urlString: String) -> String? {
		let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard var components = URLComponents(string: trimmed),
			  let scheme = components.scheme?.lowercased(),
			  scheme == "http" || scheme == "https",
			  let host = components.host, !host.isEmpty else {
			return nil
		}

		components.scheme = scheme
		components.host = host.lowercased()

		if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
			components.port = nil
		}

		// One form per post, whatever host, screen name (which can change), photo
		// suffix or share parameters the link carries.
		if components.port == nil, components.percentEncodedUser == nil,
		   let xHost = components.host, let statusID = xStatusID(host: xHost, path: components.percentEncodedPath) {
			return "https://x.com/i/status/\(statusID)"
		}

		components.fragment = nil

		// Work on the query as written: decoding and re-encoding it would change what
		// some servers see (`%2B` would become `+`, which they read as a space).
		if let query = components.percentEncodedQuery {
			let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { item in
				let encodedName = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
				let name = (String(encodedName).removingPercentEncoding ?? String(encodedName)).lowercased()
				return !name.hasPrefix("utm_") && !trackingQueryItemNames.contains(name)
			}
			let keptQuery = kept.joined(separator: "&")
			components.percentEncodedQuery = keptQuery.isEmpty ? nil : keptQuery
		}

		let path = components.percentEncodedPath
		if path.isEmpty {
			components.percentEncodedPath = "/"
		} else if path.count > 1, path.hasSuffix("/") {
			components.percentEncodedPath = String(path.dropLast())
		}

		return components.string
	}

	/// What a link to X points to.
	public enum XPage: Equatable, Sendable {
		case post(id: String)
		/// An X Article (long-form post) opened by its own address, `/i/article/<id>` or `/<user>/article/<id>`.
		case article
	}

	/// What `urlString` points to on X, or nil when it isn't a link to an X post or Article.
	public static func xPage(for urlString: String) -> XPage? {
		guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
			  let host = components.host?.lowercased() else {
			return nil
		}
		let path = components.percentEncodedPath
		if let statusID = xStatusID(host: host, path: path) {
			return .post(id: statusID)
		}
		if xHosts.contains(host), path.wholeMatch(of: /\/[A-Za-z0-9_]+\/article\/\d{1,20}(?:\/.*)?/) != nil {
			return .article
		}
		return nil
	}

	/// Matches `/<user>/status/<id>`, `/<user>/statuses/<id>` (which covers `/i/status/<id>`)
	/// and `/i/web/status/<id>`, with anything after the ID.
	private static func xStatusID(host: String, path: String) -> String? {
		guard xHosts.contains(host),
			  let match = path.wholeMatch(of: /\/(?:[^\/]+\/status(?:es)?|i\/web\/status)\/(\d{1,20})(?:\/.*)?/) else {
			return nil
		}
		return String(match.1)
	}
}
