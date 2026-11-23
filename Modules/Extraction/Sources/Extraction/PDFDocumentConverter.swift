//
//  PDFDocumentConverter.swift
//  Extraction
//
//  Extracts reflowable, structured article HTML from a PDF using PDFKit so it
//  renders in NetNewsList’s typography and supports reading-position tracking.
//  Detects headings by font size, rejoins soft-wrapped lines, de-hyphenates
//  breaks, and strips repeating running headers, footers, and page numbers.
//

import Foundation
import PDFKit
import RSCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum PDFDocumentConverter {

	public static func convert(url: URL, fallbackTitle: String? = nil) throws -> ImportedDocument {
		guard let document = PDFDocument(url: url) else {
			throw DocumentImportError.unreadablePDF
		}
		let name = fallbackTitle ?? url.deletingPathExtension().lastPathComponent
		return try convert(document: document, fallbackTitle: name)
	}

	public static func convert(data: Data, fallbackTitle: String? = nil) throws -> ImportedDocument {
		guard let document = PDFDocument(data: data) else {
			throw DocumentImportError.unreadablePDF
		}
		return try convert(document: document, fallbackTitle: fallbackTitle)
	}
}

private extension PDFDocumentConverter {

	struct StyledRun {
		let text: String
		let fontSize: CGFloat
		let isBold: Bool
		let isItalic: Bool
		let link: String?
	}

	struct ExtractedLine {
		let runs: [StyledRun]
		let plainText: String
		let dominantFontSize: CGFloat
		let isAllBold: Bool
		let isBlank: Bool
	}

	enum SemanticBlock {
		case heading(level: Int, text: String)
		case paragraph([StyledRun])
		case bulletList([[StyledRun]])
		case orderedList([[StyledRun]])
	}

	static func convert(document: PDFDocument, fallbackTitle: String?) throws -> ImportedDocument {
		let pageCount = document.pageCount
		guard pageCount > 0 else {
			throw DocumentImportError.unreadablePDF
		}

		var pageLines = [[ExtractedLine]]()
		for pageIndex in 0..<pageCount {
			guard let page = document.page(at: pageIndex) else {
				continue
			}
			let lines = extractLines(from: page)
			if !lines.isEmpty {
				pageLines.append(lines)
			}
		}

		guard !pageLines.isEmpty else {
			throw DocumentImportError.unreadablePDF
		}

		stripRunningHeadersAndFooters(&pageLines)

		let allLines = pageLines.flatMap { $0 }
		let bodyFontSize = medianFontSize(in: allLines)
		var blocks = buildBlocks(from: allLines, bodyFontSize: bodyFontSize)

		guard !blocks.isEmpty else {
			throw DocumentImportError.unreadablePDF
		}

		let metadataTitle = meaningfulMetadataTitle(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
		let metadataAuthor = nonEmpty(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)

		var title = metadataTitle
		if case .heading(level: 1, let headingText) = blocks.first {
			if title == nil {
				title = headingText
			}
			if title?.caseInsensitiveCompare(headingText) == .orderedSame {
				blocks.removeFirst()
			}
		} else if title == nil, case .heading(level: 2, let headingText) = blocks.first {
			title = headingText
			blocks.removeFirst()
		}

		let resolvedTitle = nonEmpty(title) ?? nonEmpty(fallbackTitle) ?? firstHeadingOrSentence(in: blocks) ?? NSLocalizedString("Untitled PDF", comment: "Imported PDF: fallback title")
		let html = renderBlocks(blocks).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !html.isEmpty else {
			throw DocumentImportError.unreadablePDF
		}

		let summary = makeExcerpt(from: blocks)
		return ImportedDocument(title: resolvedTitle, contentHTML: html, summary: summary, byline: metadataAuthor)
	}

	static func extractLines(from page: PDFPage) -> [ExtractedLine] {
		guard let attributed = page.attributedString, attributed.length > 0 else {
			if let plain = page.string, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return plain
					.replacingOccurrences(of: "\r\n", with: "\n")
					.replacingOccurrences(of: "\r", with: "\n")
					.components(separatedBy: "\n")
					.map { line in
						let trimmed = line.trimmingCharacters(in: .whitespaces)
						let run = StyledRun(text: trimmed, fontSize: 12, isBold: false, isItalic: false, link: nil)
						return ExtractedLine(runs: trimmed.isEmpty ? [] : [run], plainText: trimmed, dominantFontSize: 12, isAllBold: false, isBlank: trimmed.isEmpty)
					}
			}
			return []
		}

		var lines = [ExtractedLine]()
		var currentRuns = [StyledRun]()

		func flushLine() {
			let joined = currentRuns.map(\.text).joined()
			let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty {
				if !(lines.last?.isBlank ?? true) {
					lines.append(ExtractedLine(runs: [], plainText: "", dominantFontSize: 0, isAllBold: false, isBlank: true))
				}
			} else {
				let weightedSize = dominantSize(of: currentRuns)
				let nonSpaceRuns = currentRuns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
				let allBold = !nonSpaceRuns.isEmpty && nonSpaceRuns.allSatisfy(\.isBold)
				lines.append(ExtractedLine(runs: trimEdgeWhitespace(currentRuns), plainText: trimmed, dominantFontSize: weightedSize, isAllBold: allBold, isBlank: false))
			}
			currentRuns.removeAll()
		}

		let fullRange = NSRange(location: 0, length: attributed.length)
		attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
			let raw = (attributed.string as NSString).substring(with: range)
				.replacingOccurrences(of: "\r\n", with: "\n")
				.replacingOccurrences(of: "\r", with: "\n")
			let (size, bold, italic) = fontTraits(from: attributes)
			let link = linkString(from: attributes)

			let segments = raw.components(separatedBy: "\n")
			for (segmentIndex, segment) in segments.enumerated() {
				if !segment.isEmpty {
					currentRuns.append(StyledRun(text: segment, fontSize: size, isBold: bold, isItalic: italic, link: link))
				}
				if segmentIndex < segments.count - 1 {
					flushLine()
				}
			}
		}
		flushLine()

		// Add a paragraph break between pages only if the page ended cleanly; otherwise allow soft join.
		return lines
	}

	static func stripRunningHeadersAndFooters(_ pages: inout [[ExtractedLine]]) {
		let nonEmptyPages = pages.filter { $0.contains(where: { !$0.isBlank }) }
		guard nonEmptyPages.count >= 2 else {
			// Still strip standalone page numbers on single-page PDFs.
			for i in pages.indices {
				stripStandalonePageNumbers(&pages[i])
			}
			return
		}

		var firstLineCounts = [String: Int]()
		var lastLineCounts = [String: Int]()
		for page in nonEmptyPages {
			if let first = page.first(where: { !$0.isBlank })?.plainText, first.count <= 100 {
				firstLineCounts[normalizedHeaderKey(first), default: 0] += 1
			}
			if let last = page.last(where: { !$0.isBlank })?.plainText, last.count <= 100 {
				lastLineCounts[normalizedHeaderKey(last), default: 0] += 1
			}
		}

		let threshold = max(2, nonEmptyPages.count / 2)
		let repeatingHeaders = Set(firstLineCounts.filter { $0.value >= threshold }.keys)
		let repeatingFooters = Set(lastLineCounts.filter { $0.value >= threshold }.keys)

		for i in pages.indices {
			if let firstIdx = pages[i].firstIndex(where: { !$0.isBlank }),
			   repeatingHeaders.contains(normalizedHeaderKey(pages[i][firstIdx].plainText)) {
				pages[i].remove(at: firstIdx)
			}
			if let lastIdx = pages[i].lastIndex(where: { !$0.isBlank }),
			   repeatingFooters.contains(normalizedHeaderKey(pages[i][lastIdx].plainText)) {
				pages[i].remove(at: lastIdx)
			}
			stripStandalonePageNumbers(&pages[i])
		}
	}

	static func stripStandalonePageNumbers(_ lines: inout [ExtractedLine]) {
		if let firstIdx = lines.firstIndex(where: { !$0.isBlank }), isPageNumber(lines[firstIdx].plainText) {
			lines.remove(at: firstIdx)
		}
		if let lastIdx = lines.lastIndex(where: { !$0.isBlank }), isPageNumber(lines[lastIdx].plainText) {
			lines.remove(at: lastIdx)
		}
	}

	static func isPageNumber(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count <= 20 else {
			return false
		}
		return trimmed.wholeMatch(of: #/(?:[-–—]\s*)?(?:page\s*)?\d{1,5}(?:\s*(?:of|/)\s*\d{1,5})?(?:\s*[-–—])?/#.ignoresCase()) != nil
	}

	static func normalizedHeaderKey(_ text: String) -> String {
		// Strip digits so "Chapter 1   12" and "Chapter 1   13" collapse to the same key.
		text.replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
	}

	static func medianFontSize(in lines: [ExtractedLine]) -> CGFloat {
		var weighted = [CGFloat]()
		for line in lines where !line.isBlank && line.dominantFontSize > 0 {
			let weight = max(1, min(line.plainText.count / 10, 20))
			for _ in 0..<weight {
				weighted.append(line.dominantFontSize)
			}
		}
		guard !weighted.isEmpty else {
			return 12
		}
		weighted.sort()
		return weighted[weighted.count / 2]
	}

	static func buildBlocks(from lines: [ExtractedLine], bodyFontSize: CGFloat) -> [SemanticBlock] {
		var blocks = [SemanticBlock]()
		var paragraphRuns = [StyledRun]()
		var bulletItems = [[StyledRun]]()
		var orderedItems = [[StyledRun]]()
		var sawTitle = false

		func flushParagraph() {
			if !paragraphRuns.isEmpty {
				blocks.append(.paragraph(paragraphRuns))
				paragraphRuns.removeAll()
			}
		}

		func flushLists() {
			if !bulletItems.isEmpty {
				blocks.append(.bulletList(bulletItems))
				bulletItems.removeAll()
			}
			if !orderedItems.isEmpty {
				blocks.append(.orderedList(orderedItems))
				orderedItems.removeAll()
			}
		}

		for line in lines {
			if line.isBlank {
				flushParagraph()
				flushLists()
				continue
			}

			// Heading detection by font size or short bold standalone line
			let text = line.plainText
			let isShortHeadingCandidate = text.count <= 140 && !text.hasSuffix(",") && !text.hasSuffix(";")
			if isShortHeadingCandidate && line.dominantFontSize >= bodyFontSize * 1.45 {
				flushParagraph()
				flushLists()
				let level = sawTitle ? 2 : 1
				sawTitle = true
				blocks.append(.heading(level: level, text: text))
				continue
			}
			if isShortHeadingCandidate && (line.dominantFontSize >= bodyFontSize * 1.18 || (line.isAllBold && paragraphRuns.isEmpty && !text.hasSuffix(".") && text.count <= 90)) {
				flushParagraph()
				flushLists()
				blocks.append(.heading(level: line.dominantFontSize >= bodyFontSize * 1.25 ? 2 : 3, text: text))
				continue
			}

			// Bullet list item
			if let stripped = strippingBullet(from: line.runs) {
				flushParagraph()
				if !orderedItems.isEmpty {
					blocks.append(.orderedList(orderedItems))
					orderedItems.removeAll()
				}
				bulletItems.append(stripped)
				continue
			}

			// Numbered list item
			if let stripped = strippingOrderedPrefix(from: line.runs) {
				flushParagraph()
				if !bulletItems.isEmpty {
					blocks.append(.bulletList(bulletItems))
					bulletItems.removeAll()
				}
				orderedItems.append(stripped)
				continue
			}

			// Continuation of a list item or body paragraph
			if !bulletItems.isEmpty {
				bulletItems[bulletItems.count - 1] = appendLineRuns(line.runs, to: bulletItems[bulletItems.count - 1])
				continue
			}
			if !orderedItems.isEmpty {
				orderedItems[orderedItems.count - 1] = appendLineRuns(line.runs, to: orderedItems[orderedItems.count - 1])
				continue
			}

			// Soft-wrap vs new paragraph heuristic:
			// If the accumulated paragraph ended with terminal punctuation on a short line, start a new paragraph.
			if !paragraphRuns.isEmpty, shouldStartNewParagraph(after: paragraphRuns, nextLine: line) {
				flushParagraph()
			}

			paragraphRuns = appendLineRuns(line.runs, to: paragraphRuns)
		}

		flushParagraph()
		flushLists()
		return blocks
	}

	static func shouldStartNewParagraph(after current: [StyledRun], nextLine: ExtractedLine) -> Bool {
		guard let lastText = current.last?.text.trimmingCharacters(in: .whitespaces), !lastText.isEmpty else {
			return false
		}
		guard let lastChar = lastText.last, ".!?\"”’".contains(lastChar) else {
			return false
		}
		// Only break when the preceding line was notably shorter than a typical wrapped PDF line
		// and the next line begins with an uppercase letter or quote.
		let recentLineLength = lastLineCharacterCount(in: current)
		guard recentLineLength < 55, let firstNext = nextLine.plainText.first, firstNext.isUppercase || "\"“‘".contains(firstNext) else {
			return false
		}
		return true
	}

	static func lastLineCharacterCount(in runs: [StyledRun]) -> Int {
		var count = 0
		for run in runs.reversed() {
			count += run.text.count
			if count >= 60 {
				break
			}
		}
		return count
	}

	static func appendLineRuns(_ nextRuns: [StyledRun], to existing: [StyledRun]) -> [StyledRun] {
		guard !existing.isEmpty else {
			return nextRuns
		}
		guard !nextRuns.isEmpty else {
			return existing
		}
		var result = existing
		// De-hyphenate word breaks across PDF line wraps: `exam-\nple` -> `example`.
		if let last = result.last, last.text.hasSuffix("-"), !last.text.hasSuffix(" -"),
		   let firstNextChar = nextRuns.first?.text.first, firstNextChar.isLowercase {
			let stripped = String(last.text.dropLast())
			result[result.count - 1] = StyledRun(text: stripped, fontSize: last.fontSize, isBold: last.isBold, isItalic: last.isItalic, link: last.link)
			result.append(contentsOf: nextRuns)
		} else {
			result.append(StyledRun(text: " ", fontSize: nextRuns[0].fontSize, isBold: false, isItalic: false, link: nil))
			result.append(contentsOf: nextRuns)
		}
		return result
	}

	static func strippingBullet(from runs: [StyledRun]) -> [StyledRun]? {
		guard let first = runs.first else {
			return nil
		}
		let prefixes = ["• ", "◦ ", "▪ ", "‣ ", "- ", "– ", "— "]
		for prefix in prefixes where first.text.hasPrefix(prefix) {
			var copy = runs
			let rest = String(first.text.dropFirst(prefix.count))
			if rest.isEmpty {
				copy.removeFirst()
			} else {
				copy[0] = StyledRun(text: rest, fontSize: first.fontSize, isBold: first.isBold, isItalic: first.isItalic, link: first.link)
			}
			return copy.isEmpty ? nil : copy
		}
		return nil
	}

	static func strippingOrderedPrefix(from runs: [StyledRun]) -> [StyledRun]? {
		guard let first = runs.first,
			  let match = first.text.prefixMatch(of: #/^\d{1,3}[.)]\s+/#) else {
			return nil
		}
		var copy = runs
		let rest = String(first.text[match.range.upperBound...])
		if rest.isEmpty {
			copy.removeFirst()
		} else {
			copy[0] = StyledRun(text: rest, fontSize: first.fontSize, isBold: first.isBold, isItalic: first.isItalic, link: first.link)
		}
		return copy.isEmpty ? nil : copy
	}

	static func renderBlocks(_ blocks: [SemanticBlock]) -> String {
		blocks.map { block in
			switch block {
			case .heading(let level, let text):
				let clamped = min(max(level, 1), 6)
				return "<h\(clamped)>\(text.escapingSpecialXMLCharacters)</h\(clamped)>"
			case .paragraph(let runs):
				return "<p>\(renderRuns(runs))</p>"
			case .bulletList(let items):
				let lis = items.map { "<li>\(renderRuns($0))</li>" }.joined(separator: "\n")
				return "<ul>\n\(lis)\n</ul>"
			case .orderedList(let items):
				let lis = items.map { "<li>\(renderRuns($0))</li>" }.joined(separator: "\n")
				return "<ol>\n\(lis)\n</ol>"
			}
		}.joined(separator: "\n")
	}

	static func renderRuns(_ runs: [StyledRun]) -> String {
		// Merge adjacent runs with identical formatting so we don't emit `<b>a</b><b>b</b>`.
		var merged = [StyledRun]()
		for run in runs {
			if let last = merged.last, last.isBold == run.isBold, last.isItalic == run.isItalic, last.link == run.link {
				merged[merged.count - 1] = StyledRun(text: last.text + run.text, fontSize: last.fontSize, isBold: last.isBold, isItalic: last.isItalic, link: last.link)
			} else {
				merged.append(run)
			}
		}

		return merged.map { run in
			var html = run.text.escapingSpecialXMLCharacters
			if run.isItalic {
				html = "<em>\(html)</em>"
			}
			if run.isBold {
				html = "<strong>\(html)</strong>"
			}
			if let link = run.link {
				html = "<a href=\"\(link.escapingSpecialXMLCharacters)\">\(html)</a>"
			}
			return html
		}.joined()
	}

	static func fontTraits(from attributes: [NSAttributedString.Key: Any]) -> (size: CGFloat, bold: Bool, italic: Bool) {
#if canImport(AppKit)
		if let font = attributes[.font] as? NSFont {
			let traits = font.fontDescriptor.symbolicTraits
			return (font.pointSize, traits.contains(.bold), traits.contains(.italic))
		}
#elseif canImport(UIKit)
		if let font = attributes[.font] as? UIFont {
			let traits = font.fontDescriptor.symbolicTraits
			return (font.pointSize, traits.contains(.traitBold), traits.contains(.traitItalic))
		}
#endif
		return (12, false, false)
	}

	static func linkString(from attributes: [NSAttributedString.Key: Any]) -> String? {
		let url: URL?
		if let linkURL = attributes[.link] as? URL {
			url = linkURL
		} else if let linkStr = attributes[.link] as? String {
			url = URL(string: linkStr)
		} else {
			url = nil
		}
		guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "mailto" else {
			return nil
		}
		return url.absoluteString
	}

	static func dominantSize(of runs: [StyledRun]) -> CGFloat {
		var counts = [CGFloat: Int]()
		for run in runs {
			let len = run.text.trimmingCharacters(in: .whitespaces).count
			if len > 0 {
				counts[(run.fontSize * 2).rounded() / 2, default: 0] += len
			}
		}
		return counts.max(by: { $0.value < $1.value })?.key ?? 12
	}

	static func trimEdgeWhitespace(_ runs: [StyledRun]) -> [StyledRun] {
		var result = runs
		while let first = result.first {
			let trimmed = first.text.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
			if trimmed.isEmpty {
				result.removeFirst()
			} else {
				result[0] = StyledRun(text: trimmed, fontSize: first.fontSize, isBold: first.isBold, isItalic: first.isItalic, link: first.link)
				break
			}
		}
		while let last = result.last {
			let trimmed = last.text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
			if trimmed.isEmpty {
				result.removeLast()
			} else {
				result[result.count - 1] = StyledRun(text: trimmed, fontSize: last.fontSize, isBold: last.isBold, isItalic: last.isItalic, link: last.link)
				break
			}
		}
		return result
	}

	static func meaningfulMetadataTitle(_ raw: String?) -> String? {
		guard let trimmed = nonEmpty(raw) else {
			return nil
		}
		let lower = trimmed.lowercased()
		if lower.hasPrefix("microsoft word -") || lower.hasSuffix(".pdf") || lower.hasSuffix(".docx") || lower == "untitled" {
			return nil
		}
		return trimmed
	}

	static func firstHeadingOrSentence(in blocks: [SemanticBlock]) -> String? {
		for block in blocks {
			switch block {
			case .heading(_, let text):
				return String(text.prefix(100))
			case .paragraph(let runs):
				let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
				if !text.isEmpty {
					return String(text.prefix(100))
				}
			default:
				continue
			}
		}
		return nil
	}

	static func makeExcerpt(from blocks: [SemanticBlock]) -> String? {
		var parts = [String]()
		for block in blocks {
			switch block {
			case .paragraph(let runs):
				parts.append(runs.map(\.text).joined())
			case .heading(_, let text):
				parts.append(text)
			case .bulletList(let items), .orderedList(let items):
				for item in items.prefix(3) {
					parts.append(item.map(\.text).joined())
				}
			}
			if parts.joined(separator: " ").count >= 260 {
				break
			}
		}
		let collapsed = parts.joined(separator: " ").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
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
}
