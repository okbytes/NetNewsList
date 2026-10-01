//
//  ArticleImageRewriter.swift
//  NetNewsList
//
//  Points a saved article’s images at the local image store when it is shown.
//  The stored HTML keeps the original image URLs, so it stays the same on every
//  device; each device keeps its own copies. See Technotes/NetNewsList/Plan.md, 3.3.
//
//  nnlasset://<articleID>/<base64url(original image URL)>
//

import Foundation

enum ArticleImageRewriter {

	static let scheme = "nnlasset"

	private static let imageTag = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
	private static let sourceTag = try? NSRegularExpression(pattern: #"<source\b[^>]*>"#, options: [.caseInsensitive])
	private static let srcAttribute = try? NSRegularExpression(pattern: #"\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])
	private static let srcsetAttribute = try? NSRegularExpression(pattern: #"\s(?:srcset|sizes)\s*=\s*(?:"[^"]*"|'[^']*')"#, options: [.caseInsensitive])

	/// The http(s) image URLs in the HTML, in document order, without duplicates.
	static func imageURLs(in html: String, baseURL: URL?) -> [String] {
		var seen = Set<String>()
		var urls = [String]()
		forEachImageTag(in: html) { tag in
			if let url = imageURL(inTag: tag, baseURL: baseURL), seen.insert(url).inserted {
				urls.append(url)
			}
			return nil
		}
		return urls
	}

	/// The HTML with every http(s) image loading from the local store. `srcset` and
	/// `<source>` candidates are dropped so the web view can’t load around the store.
	static func rewrite(_ html: String, articleID: String, baseURL: URL?) -> String {
		var rewritten = forEachImageTag(in: html) { tag in
			guard let url = imageURL(inTag: tag, baseURL: baseURL), let srcAttribute else {
				return nil
			}
			let range = NSRange(tag.startIndex..., in: tag)
			guard let match = srcAttribute.firstMatch(in: tag, range: range), let srcRange = Range(match.range, in: tag) else {
				return nil
			}
			var newTag = tag
			newTag.replaceSubrange(srcRange, with: " src=\"\(assetURL(articleID: articleID, originalURL: url))\" data-nnl-src=\"\(url.escapingAttribute)\"")
			return removing(srcsetAttribute, from: newTag)
		}
		if let sourceTag {
			rewritten = replacingMatches(of: sourceTag, in: rewritten) { removing(srcsetAttribute, from: $0) }
		}
		return rewritten
	}

	static func assetURL(articleID: String, originalURL: String) -> String {
		"\(scheme)://\(articleID)/\(Data(originalURL.utf8).base64URLEncoded)"
	}

	/// The article ID and original image URL encoded in an asset URL.
	static func parse(assetURL url: URL) -> (articleID: String, originalURL: String)? {
		guard url.scheme?.lowercased() == scheme,
			  let articleID = url.host(percentEncoded: false), !articleID.isEmpty else {
			return nil
		}
		let encoded = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard let data = Data(base64URLEncoded: encoded), let originalURL = String(data: data, encoding: .utf8) else {
			return nil
		}
		return (articleID, originalURL)
	}
}

private extension ArticleImageRewriter {

	/// Calls `transform` for each `<img>` tag; a non-nil result replaces the tag.
	@discardableResult
	static func forEachImageTag(in html: String, transform: (String) -> String?) -> String {
		guard let imageTag else {
			return html
		}
		return replacingMatches(of: imageTag, in: html) { tag in
			transform(tag) ?? tag
		}
	}

	static func replacingMatches(of expression: NSRegularExpression, in string: String, transform: (String) -> String) -> String {
		let matches = expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
		guard !matches.isEmpty else {
			return string
		}
		var result = ""
		var cursor = string.startIndex
		for match in matches {
			guard let range = Range(match.range, in: string) else {
				continue
			}
			result += string[cursor..<range.lowerBound]
			result += transform(String(string[range]))
			cursor = range.upperBound
		}
		result += string[cursor...]
		return result
	}

	static func removing(_ expression: NSRegularExpression?, from tag: String) -> String {
		guard let expression else {
			return tag
		}
		return expression.stringByReplacingMatches(in: tag, range: NSRange(tag.startIndex..., in: tag), withTemplate: "")
	}

	static func imageURL(inTag tag: String, baseURL: URL?) -> String? {
		guard let srcAttribute,
			  let match = srcAttribute.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
			return nil
		}
		let valueRange = [1, 2].lazy.compactMap { Range(match.range(at: $0), in: tag) }.first
		guard let valueRange else {
			return nil
		}
		let value = String(tag[valueRange]).decodingAttributeEntities.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
			  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return nil
		}
		return url.absoluteString
	}
}

private extension String {

	var decodingAttributeEntities: String {
		replacingOccurrences(of: "&amp;", with: "&")
			.replacingOccurrences(of: "&#38;", with: "&")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
	}

	var escapingAttribute: String {
		replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
	}
}

extension Data {

	var base64URLEncoded: String {
		base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	init?(base64URLEncoded string: String) {
		var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while base64.count % 4 != 0 {
			base64 += "="
		}
		self.init(base64Encoded: base64)
	}
}
