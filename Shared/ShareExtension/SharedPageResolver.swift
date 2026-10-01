//
//  SharedPageResolver.swift
//  NetNewsList
//
//  Finds the page a share extension was given: Safari’s JavaScript
//  preprocessing results (SafariExt.js), a URL item, or text that is a URL.
//

import Foundation
import UniformTypeIdentifiers

struct SharedPage: Sendable {
	let url: URL
	let title: String?

	/// The article as Safari showed it, extracted in the page by SafariExt.js.
	var body: String? = nil
}

@MainActor enum SharedPageResolver {

	static func resolve(_ inputItems: [Any]) async -> SharedPage? {
		let extensionItems = inputItems.compactMap { $0 as? NSExtensionItem }
		let providers = extensionItems.compactMap(\.attachments).flatMap { $0 }
		let itemTitle = extensionItems.lazy.compactMap { item in
			nonEmpty(item.attributedTitle?.string) ?? nonEmpty(item.attributedContentText?.string)
		}.first

		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }),
		   let item = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier),
		   let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary,
		   let urlString = results["url"] as? String,
		   let url = webURL(urlString) {
			return SharedPage(url: url, title: nonEmpty(results["title"] as? String) ?? itemTitle, body: nonEmpty(results["body"] as? String))
		}

		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
		   let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
			var url = item as? URL
			if url == nil, let data = item as? Data {
				url = URL(dataRepresentation: data, relativeTo: nil)
			}
			if let url, let webURL = webURL(url.absoluteString) {
				return SharedPage(url: webURL, title: itemTitle.flatMap { $0 == url.absoluteString ? nil : $0 })
			}
		}

		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
		   let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
		   let text = item as? String,
		   let url = firstWebURL(in: text) {
			return SharedPage(url: url, title: nil)
		}

		return nil
	}
}

private extension SharedPageResolver {

	static func nonEmpty(_ string: String?) -> String? {
		guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}

	static func webURL(_ string: String) -> URL? {
		guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
			  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return nil
		}
		return url
	}

	/// Text shared from another app may wrap the link in other words.
	static func firstWebURL(in text: String) -> URL? {
		if let url = webURL(text) {
			return url
		}
		guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
			return nil
		}
		let range = NSRange(text.startIndex..., in: text)
		return detector.matches(in: text, range: range).lazy.compactMap { $0.url }.compactMap { webURL($0.absoluteString) }.first
	}
}
