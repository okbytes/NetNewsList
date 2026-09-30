//
//  URLCanonicalizer.swift
//  Account
//
//  One page, one article: two devices saving the same page must compute the same
//  article ID, so every saved URL is reduced to a canonical form first.
//
//  The browser extension implements the same rules in JavaScript. Both are checked
//  against the vectors in Tests/AccountTests/Resources/url-canonicalization.json.
//

import Foundation

public enum URLCanonicalizer {

	/// Query items that only track where a click came from.
	private static let trackingQueryItemNames: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"]

	/// Returns the canonical form of an http or https URL, or nil for anything else.
	///
	/// Rules, applied in order: lowercase the scheme and host; drop the default port;
	/// drop the fragment; drop `utm_*` and other tracking query items (keeping the
	/// rest in their original order); an empty path becomes `/`; any other path
	/// loses one trailing slash.
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

		components.fragment = nil

		if let queryItems = components.queryItems {
			let kept = queryItems.filter { item in
				let name = item.name.lowercased()
				return !name.hasPrefix("utm_") && !trackingQueryItemNames.contains(name)
			}
			components.queryItems = kept.isEmpty ? nil : kept
		}

		let path = components.percentEncodedPath
		if path.isEmpty {
			components.percentEncodedPath = "/"
		} else if path.count > 1, path.hasSuffix("/") {
			components.percentEncodedPath = String(path.dropLast())
		}

		return components.string
	}
}
