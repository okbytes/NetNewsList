//
//  SharedPageResolver.swift
//  NetNewsList
//
//  Finds what a share extension was given: a web page (Safari’s JavaScript
//  preprocessing results, a web URL, or short text containing one) or a
//  document to import (Apple Notes rich text/HTML/plain text, Markdown, RTF,
//  RTFD, WebArchive, or PDF).
//

import Foundation
import UniformTypeIdentifiers

struct SharedPage: Sendable {
	let url: URL
	let title: String?

	/// The article as Safari showed it, extracted in the page by SafariExt.js.
	var body: String?
}

struct SharedDocument: Sendable {
	let title: String?
	let body: String?
	let data: Data?
	let fileURL: URL?
	let contentTypeIdentifier: String?
}

enum SharedItem: Sendable {
	case webPage(SharedPage)
	case document(SharedDocument)
}

@MainActor enum SharedPageResolver {

	private static let supportedFileExtensions: Set<String> = [
		"md", "markdown", "mdown", "mkd", "txt", "text", "html", "htm", "rtf", "rtfd", "pdf", "webarchive"
	]

	private static let markdownTypeIdentifier = "net.daringfireball.markdown"
	private static let flatRTFDTypeIdentifier = "com.apple.flat-rtfd"

	static func resolveItem(_ inputItems: [Any]) async -> SharedItem? {
		let extensionItems = inputItems.compactMap { $0 as? NSExtensionItem }
		let providers = extensionItems.compactMap(\.attachments).flatMap { $0 }
		let itemTitle = extensionItems.lazy.compactMap { item in
			nonEmpty(item.attributedTitle?.string) ?? nonEmpty(item.attributedContentText?.string)
		}.first

		// 1. Safari JavaScript preprocessing (always a web page).
		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }),
		   let item = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier),
		   let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary,
		   let urlString = results["url"] as? String,
		   let url = webURL(urlString) {
			return .webPage(SharedPage(url: url, title: nonEmpty(results["title"] as? String) ?? itemTitle, body: nonEmpty(results["body"] as? String)))
		}

		// 2. Web URLs (http/https only; file URLs fall through to document import below).
		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }),
		   let url = await loadURL(from: provider, typeIdentifier: UTType.url.identifier),
		   let webURL = webURL(url.absoluteString) {
			return .webPage(SharedPage(url: webURL, title: itemTitle.flatMap { $0 == url.absoluteString ? nil : $0 }))
		}

		// 3. Supported local document files (PDF, Markdown, RTF, RTFD, HTML, WebArchive, plain text).
		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }),
		   let fileURL = await loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier),
		   fileURL.isFileURL,
		   isSupportedDocumentFile(fileURL) {
			let title = nonEmpty(fileURL.deletingPathExtension().lastPathComponent)
			let contentType = UTType(filenameExtension: fileURL.pathExtension.lowercased())?.identifier
			return .document(SharedDocument(title: title, body: nil, data: nil, fileURL: fileURL, contentTypeIdentifier: contentType))
		}

		// 4. Typed document attachments (PDF, RTFD, RTF, WebArchive, HTML, Markdown — e.g. Apple Notes "Send Copy" or Files).
		let richTypes: [String] = [
			UTType.pdf.identifier,
			flatRTFDTypeIdentifier,
			UTType.rtfd.identifier,
			UTType.rtf.identifier,
			UTType.webArchive.identifier,
			UTType.html.identifier,
			markdownTypeIdentifier
		]
		for typeID in richTypes {
			if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeID) }),
			   let doc = await loadDocument(from: provider, typeIdentifier: typeID, fallbackTitle: itemTitle) {
				return .document(doc)
			}
		}

		// 5. URL attachment that wasn't flagged as fileURL (some apps put file URLs under public.url).
		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
		   let url = await loadURL(from: provider, typeIdentifier: UTType.url.identifier) {
			if let webURL = webURL(url.absoluteString) {
				return .webPage(SharedPage(url: webURL, title: itemTitle.flatMap { $0 == url.absoluteString ? nil : $0 }))
			}
			if url.isFileURL, isSupportedDocumentFile(url) {
				let title = nonEmpty(url.deletingPathExtension().lastPathComponent)
				let contentType = UTType(filenameExtension: url.pathExtension.lowercased())?.identifier
				return .document(SharedDocument(title: title, body: nil, data: nil, fileURL: url, contentTypeIdentifier: contentType))
			}
		}

		// 6. Plain text: a bare URL or short link share saves as a web page;
		// longer multi-paragraph text (such as an Apple Note) imports as a document.
		if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
		   let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
			let text: String?
			if let string = item as? String {
				text = string
			} else if let data = item as? Data {
				text = String(data: data, encoding: .utf8)
			} else if let fileURL = item as? URL, fileURL.isFileURL, isSupportedDocumentFile(fileURL) {
				let title = nonEmpty(fileURL.deletingPathExtension().lastPathComponent)
				let contentType = UTType(filenameExtension: fileURL.pathExtension.lowercased())?.identifier
				return .document(SharedDocument(title: title, body: nil, data: nil, fileURL: fileURL, contentTypeIdentifier: contentType))
			} else {
				text = nil
			}
			if let text, let trimmed = nonEmpty(text) {
				if isShortLinkShare(trimmed), let url = firstWebURL(in: trimmed) {
					return .webPage(SharedPage(url: url, title: nil))
				}
				return .document(SharedDocument(title: itemTitle == trimmed ? nil : itemTitle, body: trimmed, data: nil, fileURL: nil, contentTypeIdentifier: UTType.plainText.identifier))
			}
		}

		return nil
	}

	static func resolve(_ inputItems: [Any]) async -> SharedPage? {
		guard case .webPage(let page) = await resolveItem(inputItems) else {
			return nil
		}
		return page
	}
}

private extension SharedPageResolver {

	static func loadURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
		guard let item = try? await provider.loadItem(forTypeIdentifier: typeIdentifier) else {
			return nil
		}
		if let url = item as? URL {
			return url
		}
		if let data = item as? Data {
			return URL(dataRepresentation: data, relativeTo: nil)
		}
		if let string = item as? String {
			return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		return nil
	}

	static func loadDocument(from provider: NSItemProvider, typeIdentifier: String, fallbackTitle: String?) async -> SharedDocument? {
		guard let item = try? await provider.loadItem(forTypeIdentifier: typeIdentifier) else {
			return nil
		}
		if let fileURL = item as? URL, fileURL.isFileURL {
			let title = nonEmpty(fileURL.deletingPathExtension().lastPathComponent) ?? fallbackTitle
			return SharedDocument(title: title, body: nil, data: nil, fileURL: fileURL, contentTypeIdentifier: typeIdentifier)
		}
		if let data = item as? Data, !data.isEmpty {
			if typeIdentifier == UTType.html.identifier || typeIdentifier == markdownTypeIdentifier,
			   let string = String(data: data, encoding: .utf8), let trimmed = nonEmpty(string) {
				return SharedDocument(title: fallbackTitle, body: trimmed, data: nil, fileURL: nil, contentTypeIdentifier: typeIdentifier)
			}
			return SharedDocument(title: fallbackTitle, body: nil, data: data, fileURL: nil, contentTypeIdentifier: typeIdentifier)
		}
		if let string = item as? String, let trimmed = nonEmpty(string) {
			return SharedDocument(title: fallbackTitle == trimmed ? nil : fallbackTitle, body: trimmed, data: nil, fileURL: nil, contentTypeIdentifier: typeIdentifier)
		}
		return nil
	}

	static func isSupportedDocumentFile(_ url: URL) -> Bool {
		let ext = url.pathExtension.lowercased()
		if supportedFileExtensions.contains(ext) {
			return true
		}
		if let type = UTType(filenameExtension: ext) {
			return type.conforms(to: .pdf) ||
				type.conforms(to: .html) ||
				type.conforms(to: .rtf) ||
				type.conforms(to: .rtfd) ||
				type.conforms(to: .webArchive) ||
				type.conforms(to: .plainText)
		}
		return false
	}

	/// Distinguishes a link shared with a short caption ("Check this out https://...") from
	/// a full note or article that merely mentions a URL somewhere in its body.
	static func isShortLinkShare(_ trimmed: String) -> Bool {
		if !trimmed.contains(where: \.isWhitespace) {
			return true
		}
		let lineCount = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
		return trimmed.count <= 300 && lineCount <= 3
	}

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
		// URL(string:) would take text with spaces in it as one address, percent-encoding them.
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmed.contains(where: \.isWhitespace), let url = webURL(trimmed) {
			return url
		}
		guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
			return nil
		}
		let range = NSRange(text.startIndex..., in: text)
		return detector.matches(in: text, range: range).lazy.compactMap { $0.url }.compactMap { webURL($0.absoluteString) }.first
	}
}
