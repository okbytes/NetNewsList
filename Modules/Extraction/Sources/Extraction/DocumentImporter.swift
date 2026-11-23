//
//  DocumentImporter.swift
//  Extraction
//
//  Turns local or shared documents (Apple Notes, Markdown, RTF/RTFD, HTML,
//  WebArchive, plain text, and PDF) into clean semantic HTML ready to save as
//  a reading-list article without a web source URL.
//

import Foundation
import UniformTypeIdentifiers
import RSCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A converted document ready to be stored as a reading-list article.
public struct ImportedDocument: Sendable, Equatable {
	public let title: String
	public let contentHTML: String
	public let summary: String?
	public let byline: String?

	public init(title: String, contentHTML: String, summary: String? = nil, byline: String? = nil) {
		self.title = title
		self.contentHTML = contentHTML
		self.summary = summary
		self.byline = byline
	}
}

/// Output of `ReadabilityWebExtractor.cleanImportedHTML(_:)`.
public struct CleanedImportedHTML: Sendable, Equatable {
	public let title: String?
	public let contentHTML: String?
	public let plainText: String
	public let excerpt: String?
	public let hasFormatting: Bool
	public let textLength: Int

	public init(title: String?, contentHTML: String?, plainText: String, excerpt: String?, hasFormatting: Bool, textLength: Int) {
		self.title = title
		self.contentHTML = contentHTML
		self.plainText = plainText
		self.excerpt = excerpt
		self.hasFormatting = hasFormatting
		self.textLength = textLength
	}
}

public enum DocumentImportError: LocalizedError, Sendable {
	case emptyDocument
	case unsupportedFileType(String)
	case unreadablePDF
	case fileTooLarge

	public var errorDescription: String? {
		switch self {
		case .emptyDocument:
			return NSLocalizedString("There’s no readable text in that document to import.", comment: "Document import: empty")
		case .unsupportedFileType(let name):
			return String(format: NSLocalizedString("NetNewsList can’t import “%@”.", comment: "Document import: unsupported type"), name)
		case .unreadablePDF:
			return NSLocalizedString("Couldn’t read text from this PDF. If it’s a scanned image, it has no selectable text to import.", comment: "Document import: unreadable PDF")
		case .fileTooLarge:
			return NSLocalizedString("This file is too large to import.", comment: "Document import: file too large")
		}
	}
}

public enum DocumentImporter {

	/// Maximum size of a file we read into memory for import (50 MB).
	public static let maxFileBytes = 50 * 1024 * 1024

	/// Markdown UTType (registered by macOS/iOS or synthesized by extension).
	public static let markdownType: UTType = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText

	/// All file content types accepted by Open panels, document pickers, and drag-and-drop.
	public static var supportedContentTypes: [UTType] {
		var types: [UTType] = [
			markdownType,
			.plainText,
			.html,
			.rtf,
			.rtfd,
			.pdf,
			.webArchive
		]
		if let md = UTType(filenameExtension: "md"), !types.contains(md) {
			types.append(md)
		}
		if let markdown = UTType(filenameExtension: "markdown"), !types.contains(markdown) {
			types.append(markdown)
		}
		return types
	}

	public static let supportedFileExtensions: Set<String> = [
		"md", "markdown", "mdown", "mkd", "txt", "text", "html", "htm", "rtf", "rtfd", "pdf", "webarchive"
	]

	public static func canImport(url: URL) -> Bool {
		guard url.isFileURL else {
			return false
		}
		let ext = url.pathExtension.lowercased()
		if supportedFileExtensions.contains(ext) {
			return true
		}
		if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
			return isSupported(contentType: type)
		}
		return false
	}

	public static func isSupported(contentType: UTType) -> Bool {
		contentType.conforms(to: .pdf) ||
		contentType.conforms(to: .html) ||
		contentType.conforms(to: .rtf) ||
		contentType.conforms(to: .rtfd) ||
		contentType.conforms(to: .webArchive) ||
		contentType.conforms(to: markdownType) ||
		contentType.conforms(to: .plainText)
	}

	public typealias HTMLCleaner = @MainActor @Sendable (String) async throws -> CleanedImportedHTML

	/// Imports a local file (Markdown, plain text, HTML, RTF, RTFD, WebArchive, or PDF).
	@MainActor
	public static func importFile(at url: URL, title: String? = nil, htmlCleaner: HTMLCleaner? = nil) async throws -> ImportedDocument {
		let fallbackTitle = nonEmpty(title) ?? nonEmpty(url.deletingPathExtension().lastPathComponent)
		let ext = url.pathExtension.lowercased()
		let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: ext)

		// RTFD is a directory package on disk; read it through NSAttributedString directly.
		if ext == "rtfd" || contentType?.conforms(to: .rtfd) == true {
			let attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
			return try await importAttributedString(attributed, fallbackTitle: fallbackTitle, htmlCleaner: htmlCleaner)
		}

		if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > maxFileBytes {
			throw DocumentImportError.fileTooLarge
		}

		if ext == "pdf" || contentType?.conforms(to: .pdf) == true {
			return try PDFDocumentConverter.convert(url: url, fallbackTitle: fallbackTitle)
		}

		let data = try Data(contentsOf: url)
		return try await importData(data, contentType: contentType, fileName: url.lastPathComponent, title: fallbackTitle, htmlCleaner: htmlCleaner)
	}

	/// Imports raw document bytes given a UTType or file name.
	@MainActor
	public static func importData(_ data: Data, contentType: UTType?, fileName: String? = nil, title: String? = nil, htmlCleaner: HTMLCleaner? = nil) async throws -> ImportedDocument {
		guard data.count <= maxFileBytes else {
			throw DocumentImportError.fileTooLarge
		}
		let ext = fileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
		let fallbackTitle = nonEmpty(title) ?? fileName.flatMap { nonEmpty(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) }

		if ext == "pdf" || contentType?.conforms(to: .pdf) == true {
			return try PDFDocumentConverter.convert(data: data, fallbackTitle: fallbackTitle)
		}

		if ext == "rtfd" || contentType?.conforms(to: .rtfd) == true || contentType == UTType("com.apple.flat-rtfd") {
			let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
			return try await importAttributedString(attributed, fallbackTitle: fallbackTitle, htmlCleaner: htmlCleaner)
		}

		if ext == "rtf" || contentType?.conforms(to: .rtf) == true {
			let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
			return try await importAttributedString(attributed, fallbackTitle: fallbackTitle, htmlCleaner: htmlCleaner)
		}

#if os(macOS)
		if ext == "webarchive" || contentType?.conforms(to: .webArchive) == true {
			let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.webArchive], documentAttributes: nil)
			return try await importAttributedString(attributed, fallbackTitle: fallbackTitle, htmlCleaner: htmlCleaner)
		}
#endif

		if ext == "html" || ext == "htm" || contentType?.conforms(to: .html) == true {
			guard let html = decodeText(data) else {
				throw DocumentImportError.emptyDocument
			}
			return try await importHTML(html, title: fallbackTitle, htmlCleaner: htmlCleaner)
		}

		if ["md", "markdown", "mdown", "mkd"].contains(ext) || contentType?.conforms(to: markdownType) == true {
			guard let text = decodeText(data) else {
				throw DocumentImportError.emptyDocument
			}
			return try MarkdownConverter.convert(text, fallbackTitle: fallbackTitle)
		}

		if ext == "txt" || ext == "text" || contentType?.conforms(to: .plainText) == true {
			guard let text = decodeText(data) else {
				throw DocumentImportError.emptyDocument
			}
			return try await importText(text, title: fallbackTitle, htmlCleaner: htmlCleaner)
		}

		throw DocumentImportError.unsupportedFileType(fileName ?? contentType?.localizedDescription ?? "")
	}

	/// Imports plain text, Markdown, or HTML string.
	@MainActor
	public static func importText(_ text: String, title: String? = nil, htmlCleaner: HTMLCleaner? = nil) async throws -> ImportedDocument {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw DocumentImportError.emptyDocument
		}
		if looksLikeHTML(trimmed) {
			return try await importHTML(trimmed, title: title, htmlCleaner: htmlCleaner)
		}
		if MarkdownConverter.looksLikeMarkdown(trimmed) {
			return try MarkdownConverter.convert(trimmed, fallbackTitle: title)
		}
		return try MarkdownConverter.convertPlainText(trimmed, fallbackTitle: title)
	}

	/// Imports HTML (e.g. from Apple Notes clipboard/share or an `.html` file).
	@MainActor
	public static func importHTML(_ html: String, title: String? = nil, htmlCleaner: HTMLCleaner? = nil) async throws -> ImportedDocument {
		let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw DocumentImportError.emptyDocument
		}

		if let htmlCleaner {
			let cleaned = try await htmlCleaner(trimmed)
			// An Apple Note whose content is raw Markdown syntax arrives as plain <div> lines
			// with no real rich formatting — render that Markdown into clean HTML.
			if !cleaned.hasFormatting && MarkdownConverter.looksLikeMarkdown(cleaned.plainText) {
				return try MarkdownConverter.convert(cleaned.plainText, fallbackTitle: nonEmpty(title) ?? cleaned.title)
			}
			guard let body = cleaned.contentHTML, !body.isEmpty else {
				if !cleaned.plainText.isEmpty {
					return try MarkdownConverter.convertPlainText(cleaned.plainText, fallbackTitle: nonEmpty(title) ?? cleaned.title)
				}
				throw DocumentImportError.emptyDocument
			}
			let resolvedTitle = cleaned.title ?? nonEmpty(title) ?? firstLine(of: cleaned.plainText) ?? NSLocalizedString("Untitled Note", comment: "Imported document: fallback title")
			return ImportedDocument(title: resolvedTitle, contentHTML: body, summary: cleaned.excerpt, byline: nil)
		}

		// Fallback without WebKit DOMPurify (e.g. pure unit tests): convert via NSAttributedString if possible.
		if let data = trimmed.data(using: .utf8),
		   let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
			return try await importAttributedString(attributed, fallbackTitle: title, htmlCleaner: nil)
		}
		throw DocumentImportError.emptyDocument
	}

	/// Converts an `NSAttributedString` (RTF, RTFD, Apple Notes rich text) into clean semantic HTML,
	/// preserving headings, emphasis, monospace code, lists, links, and downsampled embedded images.
	@MainActor
	public static func importAttributedString(_ attributed: NSAttributedString, fallbackTitle: String? = nil, htmlCleaner: HTMLCleaner? = nil) async throws -> ImportedDocument {
		let plainText = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !plainText.isEmpty || hasImageAttachments(attributed) else {
			throw DocumentImportError.emptyDocument
		}

		let rawHTML = semanticHTML(from: attributed)
		if let htmlCleaner {
			return try await importHTML(rawHTML, title: fallbackTitle, htmlCleaner: htmlCleaner)
		}

		// Direct conversion without WebKit cleaner (extract leading H1 if present).
		var extractedHeading: String?
		var bodyHTML = rawHTML
		if let match = bodyHTML.prefixMatch(of: #/^\s*<h1>([^<]+)</h1>\s*/#) {
			extractedHeading = unescapeBasicXMLEntities(String(match.1))
			bodyHTML = String(bodyHTML[match.range.upperBound...])
		}
		let title = nonEmpty(extractedHeading) ?? nonEmpty(fallbackTitle)
		if !hasSemanticFormatting(attributed) && MarkdownConverter.looksLikeMarkdown(plainText) {
			return try MarkdownConverter.convert(plainText, fallbackTitle: title)
		}
		let resolvedTitle = title ?? firstLine(of: plainText) ?? NSLocalizedString("Untitled Note", comment: "Imported document: fallback title")
		let summary = excerpt(from: plainText)
		return ImportedDocument(title: resolvedTitle, contentHTML: bodyHTML.isEmpty ? "<p>\(resolvedTitle.escapingSpecialXMLCharacters)</p>" : bodyHTML, summary: summary, byline: nil)
	}
}

// MARK: - NSAttributedString → Semantic HTML

private extension DocumentImporter {

	static let maxInlineImages = 20
	static let maxTotalImageBytes = 4 * 1024 * 1024
	static let maxImageDimension: CGFloat = 1200

	static func hasImageAttachments(_ attributed: NSAttributedString) -> Bool {
		var found = false
		attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
			if value is NSTextAttachment {
				found = true
				stop.pointee = true
			}
		}
		return found
	}

	static func hasSemanticFormatting(_ attributed: NSAttributedString) -> Bool {
		var sizes = Set<CGFloat>()
		var hasTrait = false
		attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attrs, _, stop in
			let (size, bold, italic, mono) = fontInfo(from: attrs)
			sizes.insert(size.rounded())
			if bold || italic || mono || attrs[.link] != nil || attrs[.attachment] != nil {
				hasTrait = true
				stop.pointee = true
			}
			if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty {
				hasTrait = true
				stop.pointee = true
			}
		}
		return hasTrait || sizes.count > 1
	}

	static func semanticHTML(from attributed: NSAttributedString) -> String {
		// Determine median body font size across non-whitespace characters.
		var sizeCounts = [CGFloat: Int]()
		let fullRange = NSRange(location: 0, length: attributed.length)
		attributed.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
			let size = pointSize(of: value)
			if size > 0 {
				sizeCounts[size.rounded(), default: 0] += range.length
			}
		}
		let bodySize = sizeCounts.max(by: { $0.value < $1.value })?.key ?? 13

		let string = attributed.string as NSString
		var htmlParts = [String]()
		var openListTag: String?
		var imageCount = 0
		var imageBytesUsed = 0
		var promotedTitle = false

		func closeListIfNeeded() {
			if let tag = openListTag {
				htmlParts.append("</\(tag)>")
				openListTag = nil
			}
		}

		var location = 0
		while location < string.length {
			let paraRange = string.paragraphRange(for: NSRange(location: location, length: 0))
			location = NSMaxRange(paraRange)

			// Exclude trailing newline characters from the paragraph range.
			var contentRange = paraRange
			while contentRange.length > 0 {
				let lastChar = string.character(at: NSMaxRange(contentRange) - 1)
				if lastChar == 0x0A || lastChar == 0x0D {
					contentRange.length -= 1
				} else {
					break
				}
			}
			guard contentRange.length > 0 else {
				closeListIfNeeded()
				continue
			}

			let paraStyle = attributed.attribute(.paragraphStyle, at: contentRange.location, effectiveRange: nil) as? NSParagraphStyle
			let listTag = listTagForParagraphStyle(paraStyle)

			var paraHTML = ""
			var paraPlainText = ""
			var paraSizes = [CGFloat: Int]()
			var allMono = true
			var hasText = false

			attributed.enumerateAttributes(in: contentRange, options: []) { attrs, range, _ in
				if let attachment = attrs[.attachment] as? NSTextAttachment {
					if let imgTag = inlineImageTag(from: attachment, imageCount: &imageCount, bytesUsed: &imageBytesUsed) {
						paraHTML += imgTag
						allMono = false
					}
					return
				}

				let chunk = string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
				guard !chunk.isEmpty else {
					return
				}
				let trimmedChunk = chunk.trimmingCharacters(in: .whitespaces)
				if !trimmedChunk.isEmpty {
					hasText = true
				}
				paraPlainText += chunk

				let (size, bold, italic, mono) = fontInfo(from: attrs)
				if !trimmedChunk.isEmpty {
					paraSizes[size.rounded(), default: 0] += trimmedChunk.count
					if !mono {
						allMono = false
					}
				}

				var piece = chunk.escapingSpecialXMLCharacters
				let strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
				if mono {
					piece = "<code>\(piece)</code>"
				}
				if strike {
					piece = "<s>\(piece)</s>"
				}
				if italic {
					piece = "<em>\(piece)</em>"
				}
				if bold {
					piece = "<strong>\(piece)</strong>"
				}
				if let link = linkURLString(from: attrs) {
					piece = "<a href=\"\(link.escapingSpecialXMLCharacters)\">\(piece)</a>"
				}
				paraHTML += piece
			}

			let trimmedPlain = paraPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !paraHTML.isEmpty else {
				continue
			}

			if let listTag {
				if openListTag != listTag {
					closeListIfNeeded()
					htmlParts.append("<\(listTag)>")
					openListTag = listTag
				}
				// Strip Cocoa's rendered list marker prefix (e.g. "\t•\t" or "\t1.\t") if present.
				let cleanedItem = stripCocoaListPrefix(paraHTML)
				htmlParts.append("<li>\(cleanedItem)</li>")
				continue
			}

			closeListIfNeeded()

			let dominantSize = paraSizes.max(by: { $0.value < $1.value })?.key ?? bodySize
			if hasText && trimmedPlain.count <= 160 && dominantSize >= max(bodySize * 1.45, 19) {
				let tag = promotedTitle ? "h2" : "h1"
				promotedTitle = true
				htmlParts.append("<\(tag)>\(trimmedPlain.escapingSpecialXMLCharacters)</\(tag)>")
			} else if hasText && trimmedPlain.count <= 160 && dominantSize >= max(bodySize * 1.18, 16) {
				htmlParts.append("<h2>\(trimmedPlain.escapingSpecialXMLCharacters)</h2>")
			} else if hasText && allMono {
				htmlParts.append("<pre><code>\(paraPlainText.escapingSpecialXMLCharacters)</code></pre>")
			} else {
				htmlParts.append("<p>\(paraHTML)</p>")
			}
		}

		closeListIfNeeded()
		return htmlParts.joined(separator: "\n")
	}

	static func listTagForParagraphStyle(_ style: NSParagraphStyle?) -> String? {
		guard let list = style?.textLists.last else {
			return nil
		}
		switch list.markerFormat {
		case .decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseLatin, .uppercaseLatin, .lowercaseRoman, .uppercaseRoman, .octal, .lowercaseHexadecimal, .uppercaseHexadecimal:
			return "ol"
		default:
			return "ul"
		}
	}

	static func stripCocoaListPrefix(_ html: String) -> String {
		html.replacingOccurrences(of: #"^\t*(?:•|◦|▪|‣|-|\d+[.)])\t+"#, with: "", options: .regularExpression)
	}

	static func inlineImageTag(from attachment: NSTextAttachment, imageCount: inout Int, bytesUsed: inout Int) -> String? {
		guard imageCount < maxInlineImages, bytesUsed < maxTotalImageBytes else {
			return nil
		}
		guard let jpegData = downsampledJPEGData(from: attachment) else {
			return nil
		}
		guard bytesUsed + jpegData.count <= maxTotalImageBytes else {
			return nil
		}
		imageCount += 1
		bytesUsed += jpegData.count
		return "<img src=\"data:image/jpeg;base64,\(jpegData.base64EncodedString())\" />"
	}

	static func downsampledJPEGData(from attachment: NSTextAttachment) -> Data? {
#if canImport(AppKit)
		let image: NSImage?
		if let existing = attachment.image {
			image = existing
		} else if let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents {
			image = NSImage(data: data)
		} else {
			image = nil
		}
		guard let image, image.size.width > 0, image.size.height > 0 else {
			return nil
		}
		let scale = min(1.0, maxImageDimension / max(image.size.width, image.size.height))
		let targetSize = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
		guard targetSize.width >= 1, targetSize.height >= 1 else {
			return nil
		}
		let resized = NSImage(size: targetSize)
		resized.lockFocus()
		image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
		resized.unlockFocus()
		guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
			return nil
		}
		return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
#elseif canImport(UIKit)
		let image: UIImage?
		if let existing = attachment.image {
			image = existing
		} else if let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents {
			image = UIImage(data: data)
		} else {
			image = nil
		}
		guard let image, image.size.width > 0, image.size.height > 0 else {
			return nil
		}
		let scale = min(1.0, maxImageDimension / max(image.size.width, image.size.height))
		let targetSize = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
		let renderer = UIGraphicsImageRenderer(size: targetSize)
		let resized = renderer.image { _ in
			image.draw(in: CGRect(origin: .zero, size: targetSize))
		}
		return resized.jpegData(compressionQuality: 0.75)
#endif
	}

	static func pointSize(of fontValue: Any?) -> CGFloat {
#if canImport(AppKit)
		return (fontValue as? NSFont)?.pointSize ?? 0
#elseif canImport(UIKit)
		return (fontValue as? UIFont)?.pointSize ?? 0
#endif
	}

	static func fontInfo(from attributes: [NSAttributedString.Key: Any]) -> (size: CGFloat, bold: Bool, italic: Bool, mono: Bool) {
#if canImport(AppKit)
		if let font = attributes[.font] as? NSFont {
			let traits = font.fontDescriptor.symbolicTraits
			return (font.pointSize, traits.contains(.bold), traits.contains(.italic), traits.contains(.monoSpace))
		}
#elseif canImport(UIKit)
		if let font = attributes[.font] as? UIFont {
			let traits = font.fontDescriptor.symbolicTraits
			return (font.pointSize, traits.contains(.traitBold), traits.contains(.traitItalic), traits.contains(.traitMonoSpace))
		}
#endif
		return (13, false, false, false)
	}

	static func linkURLString(from attributes: [NSAttributedString.Key: Any]) -> String? {
		let url: URL?
		if let linkURL = attributes[.link] as? URL {
			url = linkURL
		} else if let str = attributes[.link] as? String {
			url = URL(string: str)
		} else {
			url = nil
		}
		guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "mailto" else {
			return nil
		}
		return url.absoluteString
	}

	static func looksLikeHTML(_ text: String) -> Bool {
		text.range(of: #"<(?:!doctype\s+html|html|head|body|p|div|article|section|h[1-6]|ul|ol|li|blockquote|pre|table)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
	}

	static func decodeText(_ data: Data) -> String? {
		if let utf8 = String(data: data, encoding: .utf8) {
			return utf8
		}
		if let utf16 = String(data: data, encoding: .utf16) {
			return utf16
		}
		return String(data: data, encoding: .isoLatin1)
	}

	static func firstLine(of text: String) -> String? {
		let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		guard let first = lines.first else {
			return nil
		}
		return String(first.prefix(100))
	}

	static func excerpt(from text: String) -> String? {
		let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
		guard !collapsed.isEmpty else {
			return nil
		}
		return collapsed.count > 240 ? String(collapsed.prefix(240)).trimmingCharacters(in: .whitespaces) + "…" : collapsed
	}

	static func nonEmpty(_ value: String?) -> String? {
		guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}

	static func unescapeBasicXMLEntities(_ value: String) -> String {
		value.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
			.replacingOccurrences(of: "&apos;", with: "'")
			.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&amp;", with: "&")
	}
}
