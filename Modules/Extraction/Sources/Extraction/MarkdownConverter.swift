//
//  MarkdownConverter.swift
//  Extraction
//
//  Converts Markdown (and plain text) into clean semantic HTML suitable for
//  NetNewsList’s article renderer. Extracts a leading `# Heading` or YAML
//  frontmatter title so the title isn’t duplicated beneath the article header.
//

import Foundation
import RSCore

public enum MarkdownConverter {

	/// Heuristic check for whether plain text contains Markdown syntax rather than
	/// ordinary prose. Used when importing plain text or unformatted notes.
	public static func looksLikeMarkdown(_ text: String) -> Bool {
		let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
			.components(separatedBy: "\n")

		var score = 0
		var hasHeading = false
		var hasFence = false

		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				hasFence = true
				score += 2
			} else if atxHeading(in: trimmed) != nil {
				hasHeading = true
				score += 2
			} else if trimmed.hasPrefix("> ") {
				score += 1
			} else if unorderedListItem(in: line) != nil || orderedListItem(in: line) != nil {
				score += 1
			}
		}

		if hasHeading || hasFence {
			return true
		}

		// Inline Markdown markers: links `[label](https://...)`, bold `**text**`, inline code `` `code` ``.
		if text.range(of: #"\[[^\]\n]+\]\(https?://[^\s)]+\)"#, options: .regularExpression) != nil {
			score += 2
		}
		if text.range(of: #"\*\*[^*\n]{2,}\*\*"#, options: .regularExpression) != nil {
			score += 2
		}
		if text.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil {
			score += 1
		}

		return score >= 2
	}

	/// Converts Markdown text into an `ImportedDocument` with clean semantic HTML.
	public static func convert(_ markdown: String, fallbackTitle: String? = nil) throws -> ImportedDocument {
		let normalized = markdown
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")

		let (frontmatter, bodyText) = stripFrontmatter(normalized)
		let lines = bodyText.components(separatedBy: "\n")
		var blocks = parseBlocks(lines)

		guard !blocks.isEmpty else {
			throw DocumentImportError.emptyDocument
		}

		var title = frontmatter.title
		// Use a leading H1 as the article title and drop it from the body so it isn’t duplicated.
		if case .heading(level: 1, let headingText) = blocks.first {
			if title == nil {
				title = stripInlineMarkdown(headingText)
			}
			blocks.removeFirst()
		}

		let resolvedTitle = nonEmpty(title) ?? nonEmpty(fallbackTitle) ?? defaultTitle(from: blocks) ?? NSLocalizedString("Untitled Note", comment: "Imported document: fallback title")
		let html = renderBlocks(blocks).trimmingCharacters(in: .whitespacesAndNewlines)
		let finalHTML = html.isEmpty ? "<p>\(resolvedTitle.escapingSpecialXMLCharacters)</p>" : html
		let summary = makeExcerpt(from: blocks)

		return ImportedDocument(title: resolvedTitle, contentHTML: finalHTML, summary: summary, byline: frontmatter.author)
	}

	/// Converts plain text (without Markdown formatting) into clean HTML paragraphs and lists.
	public static func convertPlainText(_ text: String, fallbackTitle: String? = nil) throws -> ImportedDocument {
		let normalized = text
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !normalized.isEmpty else {
			throw DocumentImportError.emptyDocument
		}

		// Split into blank-line-separated blocks, preserving bullet/numbered lists.
		let lines = normalized.components(separatedBy: "\n")
		var paragraphs = [[String]]()
		var current = [String]()
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty {
				if !current.isEmpty {
					paragraphs.append(current)
					current.removeAll()
				}
			} else {
				current.append(trimmed)
			}
		}
		if !current.isEmpty {
			paragraphs.append(current)
		}

		var title = nonEmpty(fallbackTitle)
		// If no explicit title was supplied and the note starts with a short single-line title
		// followed by additional paragraphs (the standard Apple Notes structure), promote it.
		if title == nil, paragraphs.count > 1, paragraphs[0].count == 1, paragraphs[0][0].count <= 140 {
			title = paragraphs.removeFirst()[0]
		} else if title == nil, let firstLine = paragraphs.first?.first {
			title = String(firstLine.prefix(100))
		}

		var htmlParts = [String]()
		var plainParts = [String]()

		for group in paragraphs {
			if group.allSatisfy({ isBulletLine($0) }) {
				let items = group.map { stripBulletPrefix($0) }
				plainParts.append(contentsOf: items)
				let lis = items.map { "<li>\(linkifyPlainText($0))</li>" }.joined(separator: "\n")
				htmlParts.append("<ul>\n\(lis)\n</ul>")
			} else if group.allSatisfy({ orderedListItem(in: $0) != nil }) {
				let items = group.compactMap { orderedListItem(in: $0)?.content }
				plainParts.append(contentsOf: items)
				let lis = items.map { "<li>\(linkifyPlainText($0))</li>" }.joined(separator: "\n")
				htmlParts.append("<ol>\n\(lis)\n</ol>")
			} else {
				let joined = group.joined(separator: "\n")
				plainParts.append(joined)
				let escapedLines = group.map { linkifyPlainText($0) }.joined(separator: "<br />")
				htmlParts.append("<p>\(escapedLines)</p>")
			}
		}

		let resolvedTitle = title ?? NSLocalizedString("Untitled Note", comment: "Imported document: fallback title")
		let html = htmlParts.joined(separator: "\n")
		let summary = excerpt(fromPlainText: plainParts.joined(separator: " "))
		return ImportedDocument(title: resolvedTitle, contentHTML: html, summary: summary, byline: nil)
	}
}

// MARK: - Block AST

private extension MarkdownConverter {

	struct Frontmatter {
		var title: String?
		var author: String?
	}

	enum ListKind {
		case unordered
		case ordered(start: Int)
	}

	struct ListItem {
		let content: String
		let checked: Bool?
		let subBlocks: [Block]
	}

	indirect enum Block {
		case heading(level: Int, text: String)
		case paragraph(String)
		case codeBlock(language: String?, code: String)
		case blockquote([Block])
		case list(kind: ListKind, items: [ListItem])
		case table(headers: [String], alignments: [String?], rows: [[String]])
		case horizontalRule
	}

	static func stripFrontmatter(_ text: String) -> (Frontmatter, String) {
		var frontmatter = Frontmatter()
		guard text.hasPrefix("---\n") else {
			return (frontmatter, text)
		}
		let lines = text.components(separatedBy: "\n")
		var closingIndex: Int?
		for i in 1..<lines.count {
			let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
			if trimmed == "---" || trimmed == "..." {
				closingIndex = i
				break
			}
		}
		guard let end = closingIndex else {
			return (frontmatter, text)
		}
		for i in 1..<end {
			let line = lines[i]
			guard let colon = line.firstIndex(of: ":") else {
				continue
			}
			let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
			var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
				value = String(value.dropFirst().dropLast())
			}
			guard !value.isEmpty else {
				continue
			}
			if key == "title", frontmatter.title == nil {
				frontmatter.title = value
			} else if key == "author", frontmatter.author == nil {
				frontmatter.author = value
			}
		}
		let rest = lines[(end + 1)...].joined(separator: "\n")
		return (frontmatter, rest)
	}

	static func parseBlocks(_ lines: [String]) -> [Block] {
		var blocks = [Block]()
		var index = 0

		while index < lines.count {
			let line = lines[index]
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			if trimmed.isEmpty {
				index += 1
				continue
			}

			// Fenced code block (``` or ~~~)
			if let fence = codeFence(in: trimmed) {
				index += 1
				var codeLines = [String]()
				while index < lines.count {
					let candidate = lines[index].trimmingCharacters(in: .whitespaces)
					if candidate.hasPrefix(String(repeating: fence.marker, count: fence.length)),
					   candidate.allSatisfy({ $0 == fence.marker }) {
						index += 1
						break
					}
					codeLines.append(lines[index])
					index += 1
				}
				blocks.append(.codeBlock(language: fence.language, code: codeLines.joined(separator: "\n")))
				continue
			}

			// Indented code block (4 spaces or a tab)
			if line.hasPrefix("    ") || line.hasPrefix("\t") {
				var codeLines = [String]()
				while index < lines.count {
					let current = lines[index]
					if current.hasPrefix("    ") {
						codeLines.append(String(current.dropFirst(4)))
						index += 1
					} else if current.hasPrefix("\t") {
						codeLines.append(String(current.dropFirst(1)))
						index += 1
					} else if current.trimmingCharacters(in: .whitespaces).isEmpty {
						codeLines.append("")
						index += 1
					} else {
						break
					}
				}
				while codeLines.last == "" {
					codeLines.removeLast()
				}
				blocks.append(.codeBlock(language: nil, code: codeLines.joined(separator: "\n")))
				continue
			}

			// Horizontal rule (check before unordered list so `* * *` or `- - -` isn't parsed as list)
			if isHorizontalRule(trimmed) {
				blocks.append(.horizontalRule)
				index += 1
				continue
			}

			// ATX Heading
			if let heading = atxHeading(in: trimmed) {
				blocks.append(.heading(level: heading.level, text: heading.text))
				index += 1
				continue
			}

			// Blockquote
			if trimmed.hasPrefix(">") {
				var quoteLines = [String]()
				while index < lines.count {
					let currentTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
					if currentTrimmed.hasPrefix(">") {
						var stripped = String(currentTrimmed.dropFirst())
						if stripped.hasPrefix(" ") {
							stripped.removeFirst()
						}
						quoteLines.append(stripped)
						index += 1
					} else if !currentTrimmed.isEmpty && !quoteLines.isEmpty && !(quoteLines.last?.isEmpty ?? true) && !startsNewBlock(lines[index]) {
						quoteLines.append(lines[index])
						index += 1
					} else {
						break
					}
				}
				blocks.append(.blockquote(parseBlocks(quoteLines)))
				continue
			}

			// GFM Pipe Table
			if index + 1 < lines.count,
			   let alignments = parseTableSeparator(lines[index + 1]),
			   let headers = parseTableRow(line),
			   headers.count == alignments.count {
				index += 2
				var rows = [[String]]()
				while index < lines.count {
					let rowLine = lines[index]
					if rowLine.trimmingCharacters(in: .whitespaces).isEmpty || !rowLine.contains("|") {
						break
					}
					if var cells = parseTableRow(rowLine) {
						while cells.count < headers.count {
							cells.append("")
						}
						if cells.count > headers.count {
							cells = Array(cells.prefix(headers.count))
						}
						rows.append(cells)
					} else {
						break
					}
					index += 1
				}
				blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
				continue
			}

			// Unordered or Ordered List
			if let list = parseList(lines, startIndex: &index) {
				blocks.append(list)
				continue
			}

			// Setext heading (paragraph line followed by === or ---)
			if index + 1 < lines.count, let level = setextUnderlineLevel(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
				blocks.append(.heading(level: level, text: trimmed))
				index += 2
				continue
			}

			// Paragraph
			var paragraphLines = [trimmed]
			index += 1
			while index < lines.count {
				let next = lines[index]
				let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
				if nextTrimmed.isEmpty {
					break
				}
				// Check for Setext heading underline on the second line
				if paragraphLines.count == 1, let level = setextUnderlineLevel(nextTrimmed) {
					blocks.append(.heading(level: level, text: paragraphLines[0]))
					paragraphLines.removeAll()
					index += 1
					break
				}
				if startsNewBlock(next) {
					break
				}
				paragraphLines.append(nextTrimmed)
				index += 1
			}
			if !paragraphLines.isEmpty {
				blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
			}
		}

		return blocks
	}

	static func parseList(_ lines: [String], startIndex index: inout Int) -> Block? {
		let firstLine = lines[index]
		let kind: ListKind
		let baseIndent: Int

		if let unordered = unorderedListItem(in: firstLine) {
			kind = .unordered
			baseIndent = unordered.indent
		} else if let ordered = orderedListItem(in: firstLine) {
			kind = .ordered(start: ordered.number)
			baseIndent = ordered.indent
		} else {
			return nil
		}

		var items = [ListItem]()

		while index < lines.count {
			let line = lines[index]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty {
				// Look ahead: if the next non-empty line continues this list at baseIndent, keep going.
				var lookahead = index + 1
				while lookahead < lines.count && lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
					lookahead += 1
				}
				if lookahead < lines.count, matchesListKind(lines[lookahead], kind: kind, indent: baseIndent) {
					index = lookahead
					continue
				}
				break
			}

			let parsedItem: (content: String, contentIndent: Int)?
			switch kind {
			case .unordered:
				if let u = unorderedListItem(in: line), u.indent == baseIndent, !isHorizontalRule(trimmed) {
					parsedItem = (u.content, u.contentIndent)
				} else {
					parsedItem = nil
				}
			case .ordered:
				if let o = orderedListItem(in: line), o.indent == baseIndent {
					parsedItem = (o.content, o.contentIndent)
				} else {
					parsedItem = nil
				}
			}

			guard let itemInfo = parsedItem else {
				break
			}

			var textLines = [String]()
			var checked: Bool?
			var firstContent = itemInfo.content
			if case .unordered = kind {
				if firstContent.hasPrefix("[ ] ") {
					checked = false
					firstContent = String(firstContent.dropFirst(4))
				} else if firstContent.hasPrefix("[x] ") || firstContent.hasPrefix("[X] ") {
					checked = true
					firstContent = String(firstContent.dropFirst(4))
				}
			}
			textLines.append(firstContent)
			index += 1

			var nestedLines = [String]()
			while index < lines.count {
				let nextLine = lines[index]
				let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
				if nextTrimmed.isEmpty {
					// Keep blank line only if followed by indented continuation
					if index + 1 < lines.count && leadingSpaces(in: lines[index + 1]) >= itemInfo.contentIndent {
						nestedLines.append("")
						index += 1
						continue
					}
					break
				}
				let nextIndent = leadingSpaces(in: nextLine)
				if nextIndent > baseIndent && (unorderedListItem(in: nextLine) != nil || orderedListItem(in: nextLine) != nil || nextIndent >= itemInfo.contentIndent) {
					let stripCount = min(nextIndent, itemInfo.contentIndent)
					nestedLines.append(dropLeadingColumns(nextLine, count: stripCount))
					index += 1
				} else if nextIndent == baseIndent && (unorderedListItem(in: nextLine) != nil || orderedListItem(in: nextLine) != nil) {
					break
				} else if !startsNewBlock(nextLine) && nestedLines.isEmpty {
					textLines.append(nextTrimmed)
					index += 1
				} else {
					break
				}
			}

			let subBlocks = nestedLines.isEmpty ? [] : parseBlocks(nestedLines)
			items.append(ListItem(content: textLines.joined(separator: " "), checked: checked, subBlocks: subBlocks))
		}

		guard !items.isEmpty else {
			return nil
		}
		return .list(kind: kind, items: items)
	}

	static func matchesListKind(_ line: String, kind: ListKind, indent: Int) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard !isHorizontalRule(trimmed) else {
			return false
		}
		switch kind {
		case .unordered:
			return unorderedListItem(in: line)?.indent == indent
		case .ordered:
			return orderedListItem(in: line)?.indent == indent
		}
	}

	static func startsNewBlock(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty {
			return true
		}
		if atxHeading(in: trimmed) != nil || codeFence(in: trimmed) != nil || isHorizontalRule(trimmed) {
			return true
		}
		if trimmed.hasPrefix(">") {
			return true
		}
		if unorderedListItem(in: line) != nil || orderedListItem(in: line) != nil {
			return true
		}
		return false
	}
}

// MARK: - Line Matchers

private extension MarkdownConverter {

	static func leadingSpaces(in line: String) -> Int {
		var count = 0
		for char in line {
			if char == " " {
				count += 1
			} else if char == "\t" {
				count += 4
			} else {
				break
			}
		}
		return count
	}

	static func dropLeadingColumns(_ line: String, count: Int) -> String {
		var remaining = count
		var index = line.startIndex
		while index < line.endIndex && remaining > 0 {
			if line[index] == " " {
				remaining -= 1
				index = line.index(after: index)
			} else if line[index] == "\t" {
				remaining -= 4
				index = line.index(after: index)
			} else {
				break
			}
		}
		return String(line[index...])
	}

	static func atxHeading(in trimmed: String) -> (level: Int, text: String)? {
		var level = 0
		var idx = trimmed.startIndex
		while idx < trimmed.endIndex && trimmed[idx] == "#" && level < 7 {
			level += 1
			idx = trimmed.index(after: idx)
		}
		guard level >= 1 && level <= 6 else {
			return nil
		}
		guard idx == trimmed.endIndex || trimmed[idx] == " " || trimmed[idx] == "\t" else {
			return nil
		}
		var text = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
		// Strip optional closing hashes preceded by whitespace.
		while text.hasSuffix("#") {
			let dropped = text.dropLast()
			if dropped.isEmpty || dropped.last == " " || dropped.last == "\t" || dropped.last == "#" {
				text = String(dropped)
			} else {
				break
			}
		}
		text = text.trimmingCharacters(in: .whitespaces)
		guard !text.isEmpty else {
			return nil
		}
		return (level, text)
	}

	static func setextUnderlineLevel(_ trimmed: String) -> Int? {
		guard trimmed.count >= 2 else {
			return nil
		}
		if trimmed.allSatisfy({ $0 == "=" }) {
			return 1
		}
		if trimmed.allSatisfy({ $0 == "-" }) {
			return 2
		}
		return nil
	}

	static func isHorizontalRule(_ trimmed: String) -> Bool {
		let compact = trimmed.filter { $0 != " " && $0 != "\t" }
		guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else {
			return false
		}
		return compact.allSatisfy { $0 == first }
	}

	static func codeFence(in trimmed: String) -> (marker: Character, length: Int, language: String?)? {
		guard let first = trimmed.first, first == "`" || first == "~" else {
			return nil
		}
		var count = 0
		var idx = trimmed.startIndex
		while idx < trimmed.endIndex && trimmed[idx] == first {
			count += 1
			idx = trimmed.index(after: idx)
		}
		guard count >= 3 else {
			return nil
		}
		let info = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
		if first == "`" && info.contains("`") {
			return nil
		}
		let language = info.split(separator: " ").first.map(String.init)
		return (first, count, language)
	}

	static func unorderedListItem(in line: String) -> (indent: Int, content: String, contentIndent: Int)? {
		let indent = leadingSpaces(in: line)
		let rest = dropLeadingColumns(line, count: indent)
		guard rest.count >= 2, let marker = rest.first, marker == "-" || marker == "*" || marker == "+" || marker == "•" else {
			return nil
		}
		let afterMarker = rest.index(after: rest.startIndex)
		guard rest[afterMarker] == " " || rest[afterMarker] == "\t" else {
			return nil
		}
		let content = String(rest[rest.index(after: afterMarker)...]).trimmingCharacters(in: .whitespaces)
		guard !content.isEmpty else {
			return nil
		}
		return (indent, content, indent + 2)
	}

	static func orderedListItem(in line: String) -> (indent: Int, number: Int, content: String, contentIndent: Int)? {
		let indent = leadingSpaces(in: line)
		let rest = dropLeadingColumns(line, count: indent)
		var idx = rest.startIndex
		var digits = ""
		while idx < rest.endIndex && rest[idx].isNumber && digits.count < 9 {
			digits.append(rest[idx])
			idx = rest.index(after: idx)
		}
		guard !digits.isEmpty, let number = Int(digits), idx < rest.endIndex, rest[idx] == "." || rest[idx] == ")" else {
			return nil
		}
		let afterPunct = rest.index(after: idx)
		guard afterPunct < rest.endIndex, rest[afterPunct] == " " || rest[afterPunct] == "\t" else {
			return nil
		}
		let content = String(rest[rest.index(after: afterPunct)...]).trimmingCharacters(in: .whitespaces)
		guard !content.isEmpty else {
			return nil
		}
		return (indent, number, content, indent + digits.count + 2)
	}

	static func parseTableRow(_ line: String) -> [String]? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.contains("|") else {
			return nil
		}
		var inner = trimmed
		if inner.hasPrefix("|") {
			inner.removeFirst()
		}
		if inner.hasSuffix("|") && !inner.hasSuffix("\\|") {
			inner.removeLast()
		}
		var cells = [String]()
		var current = ""
		var escaped = false
		for ch in inner {
			if escaped {
				current.append(ch)
				escaped = false
			} else if ch == "\\" {
				escaped = true
			} else if ch == "|" {
				cells.append(current.trimmingCharacters(in: .whitespaces))
				current = ""
			} else {
				current.append(ch)
			}
		}
		cells.append(current.trimmingCharacters(in: .whitespaces))
		return cells.isEmpty ? nil : cells
	}

	static func parseTableSeparator(_ line: String) -> [String?]? {
		guard let cells = parseTableRow(line), !cells.isEmpty else {
			return nil
		}
		var alignments = [String?]()
		for cell in cells {
			guard cell.count >= 3 || (cell.count >= 1 && cell.allSatisfy({ $0 == "-" || $0 == ":" })) else {
				return nil
			}
			let left = cell.hasPrefix(":")
			let right = cell.hasSuffix(":")
			let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
			guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else {
				return nil
			}
			if left && right {
				alignments.append("center")
			} else if right {
				alignments.append("right")
			} else if left {
				alignments.append("left")
			} else {
				alignments.append(nil)
			}
		}
		return alignments
	}

	static func isBulletLine(_ trimmed: String) -> Bool {
		for prefix in ["• ", "- ", "* ", "– ", "— "] {
			if trimmed.hasPrefix(prefix) && trimmed.count > prefix.count {
				return true
			}
		}
		return false
	}

	static func stripBulletPrefix(_ trimmed: String) -> String {
		for prefix in ["• ", "- ", "* ", "– ", "— "] where trimmed.hasPrefix(prefix) {
			return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
		}
		return trimmed
	}
}

// MARK: - Rendering

private extension MarkdownConverter {

	static func renderBlocks(_ blocks: [Block]) -> String {
		blocks.map(renderBlock).joined(separator: "\n")
	}

	static func renderBlock(_ block: Block) -> String {
		switch block {
		case .heading(let level, let text):
			let clamped = min(max(level, 1), 6)
			return "<h\(clamped)>\(renderInline(text))</h\(clamped)>"

		case .paragraph(let text):
			return "<p>\(renderInline(text))</p>"

		case .codeBlock(let language, let code):
			let escaped = code.escapingSpecialXMLCharacters
			if let language, !language.isEmpty {
				let safeLang = language.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
				if !safeLang.isEmpty {
					return "<pre><code class=\"language-\(safeLang)\">\(escaped)</code></pre>"
				}
			}
			return "<pre><code>\(escaped)</code></pre>"

		case .blockquote(let inner):
			return "<blockquote>\n\(renderBlocks(inner))\n</blockquote>"

		case .list(let kind, let items):
			let renderedItems = items.map { item -> String in
				var body = renderInline(item.content)
				if let checked = item.checked {
					body = (checked ? "☑ " : "☐ ") + body
				}
				if !item.subBlocks.isEmpty {
					body += "\n" + renderBlocks(item.subBlocks)
				}
				return "<li>\(body)</li>"
			}.joined(separator: "\n")

			switch kind {
			case .unordered:
				return "<ul>\n\(renderedItems)\n</ul>"
			case .ordered(let start):
				if start != 1 {
					return "<ol start=\"\(start)\">\n\(renderedItems)\n</ol>"
				}
				return "<ol>\n\(renderedItems)\n</ol>"
			}

		case .table(let headers, let alignments, let rows):
			func alignAttr(_ index: Int) -> String {
				guard index < alignments.count, let alignment = alignments[index] else {
					return ""
				}
				return " align=\"\(alignment)\""
			}
			let headerCells = headers.enumerated().map { "<th\(alignAttr($0.offset))>\(renderInline($0.element))</th>" }.joined()
			let bodyRows = rows.map { row in
				let cells = row.enumerated().map { "<td\(alignAttr($0.offset))>\(renderInline($0.element))</td>" }.joined()
				return "<tr>\(cells)</tr>"
			}.joined(separator: "\n")
			return "<table>\n<thead><tr>\(headerCells)</tr></thead>\n<tbody>\n\(bodyRows)\n</tbody>\n</table>"

		case .horizontalRule:
			return "<hr />"
		}
	}

	static func renderInline(_ input: String) -> String {
		var result = ""
		var idx = input.startIndex

		while idx < input.endIndex {
			let ch = input[idx]

			// Backslash escape for ASCII punctuation
			if ch == "\\", let next = input.index(idx, offsetBy: 1, limitedBy: input.endIndex), next < input.endIndex {
				let escaped = input[next]
				if escaped == "\n" {
					result += "<br />"
					idx = input.index(after: next)
					continue
				}
				if escaped.isASCII && escaped.isPunctuation || escaped == "`" || escaped == "~" || escaped == "|" {
					result += String(escaped).escapingSpecialXMLCharacters
					idx = input.index(after: next)
					continue
				}
			}

			// Hard line break (two spaces + newline) or soft newline
			if ch == "\n" {
				if result.hasSuffix("  ") {
					result.removeLast(2)
					result += "<br />"
				} else {
					result += "\n"
				}
				idx = input.index(after: idx)
				continue
			}

			// Inline code span (`` `code` ``)
			if ch == "`" {
				var tickEnd = idx
				while tickEnd < input.endIndex && input[tickEnd] == "`" {
					tickEnd = input.index(after: tickEnd)
				}
				let delimiter = String(input[idx..<tickEnd])
				if let closeRange = input.range(of: delimiter, range: tickEnd..<input.endIndex) {
					var code = String(input[tickEnd..<closeRange.lowerBound])
					if code.count >= 2 && code.hasPrefix(" ") && code.hasSuffix(" ") && !code.trimmingCharacters(in: .whitespaces).isEmpty {
						code = String(code.dropFirst().dropLast())
					}
					result += "<code>\(code.escapingSpecialXMLCharacters)</code>"
					idx = closeRange.upperBound
					continue
				}
				result += delimiter
				idx = tickEnd
				continue
			}

			// Image `![alt](url)`
			if ch == "!", let bracketStart = input.index(idx, offsetBy: 1, limitedBy: input.endIndex), bracketStart < input.endIndex, input[bracketStart] == "[" {
				if let (label, destination, endIdx) = parseLinkOrImage(in: input, from: bracketStart) {
					if let safeURL = safeDestinationURL(destination, allowDataImage: true) {
						let alt = stripInlineMarkdown(label).escapingSpecialXMLCharacters
						result += "<img src=\"\(safeURL.escapingSpecialXMLCharacters)\" alt=\"\(alt)\" />"
					}
					idx = endIdx
					continue
				}
			}

			// Link `[text](url)`
			if ch == "[" {
				if let (label, destination, endIdx) = parseLinkOrImage(in: input, from: idx) {
					if let safeURL = safeDestinationURL(destination, allowDataImage: false) {
						result += "<a href=\"\(safeURL.escapingSpecialXMLCharacters)\">\(renderInline(label))</a>"
					} else {
						result += renderInline(label)
					}
					idx = endIdx
					continue
				}
			}

			// Autolink `<https://...>` or `<mailto:...>`
			if ch == "<", let close = input[input.index(after: idx)...].firstIndex(of: ">") {
				let candidate = String(input[input.index(after: idx)..<close])
				if !candidate.contains(where: \.isWhitespace), let safeURL = safeDestinationURL(candidate, allowDataImage: false) {
					result += "<a href=\"\(safeURL.escapingSpecialXMLCharacters)\">\(candidate.escapingSpecialXMLCharacters)</a>"
					idx = input.index(after: close)
					continue
				}
			}

			// Strikethrough `~~text~~`
			if ch == "~", input[idx...].hasPrefix("~~") {
				let contentStart = input.index(idx, offsetBy: 2)
				if let close = input.range(of: "~~", range: contentStart..<input.endIndex), close.lowerBound > contentStart {
					let inner = String(input[contentStart..<close.lowerBound])
					result += "<del>\(renderInline(inner))</del>"
					idx = close.upperBound
					continue
				}
			}

			// Bold+Italic `***` or `___`, Bold `**` or `__`, Italic `*` or `_`
			if ch == "*" || ch == "_" {
				if let (tag, inner, endIdx) = parseEmphasis(in: input, from: idx, marker: ch) {
					switch tag {
					case .boldItalic:
						result += "<strong><em>\(renderInline(inner))</em></strong>"
					case .bold:
						result += "<strong>\(renderInline(inner))</strong>"
					case .italic:
						result += "<em>\(renderInline(inner))</em>"
					}
					idx = endIdx
					continue
				}
			}

			result += String(ch).escapingSpecialXMLCharacters
			idx = input.index(after: idx)
		}

		return result
	}

	enum EmphasisKind {
		case boldItalic
		case bold
		case italic
	}

	static func parseEmphasis(in input: String, from idx: String.Index, marker: Character) -> (EmphasisKind, String, String.Index)? {
		// Avoid splitting snake_case words like `foo_bar_baz`.
		if marker == "_", idx > input.startIndex {
			let prev = input[input.index(before: idx)]
			if prev.isLetter || prev.isNumber {
				return nil
			}
		}

		let triple = String(repeating: marker, count: 3)
		let double = String(repeating: marker, count: 2)
		let single = String(marker)

		let candidates: [(String, EmphasisKind)] = [(triple, .boldItalic), (double, .bold), (single, .italic)]
		for (delimiter, kind) in candidates {
			guard input[idx...].hasPrefix(delimiter) else {
				continue
			}
			let contentStart = input.index(idx, offsetBy: delimiter.count)
			guard contentStart < input.endIndex, !input[contentStart].isWhitespace else {
				continue
			}
			var searchStart = contentStart
			while let close = input.range(of: delimiter, range: searchStart..<input.endIndex) {
				let beforeClose = input[input.index(before: close.lowerBound)]
				let validWordBoundary: Bool = {
					if marker == "_", close.upperBound < input.endIndex {
						let after = input[close.upperBound]
						if after.isLetter || after.isNumber {
							return false
						}
					}
					return true
				}()
				if !beforeClose.isWhitespace && validWordBoundary && close.lowerBound > contentStart {
					return (kind, String(input[contentStart..<close.lowerBound]), close.upperBound)
				}
				searchStart = close.upperBound
			}
		}
		return nil
	}

	static func parseLinkOrImage(in input: String, from openBracket: String.Index) -> (label: String, destination: String, endIndex: String.Index)? {
		var depth = 0
		var idx = openBracket
		var closeBracket: String.Index?
		while idx < input.endIndex {
			let ch = input[idx]
			if ch == "\\" {
				idx = input.index(idx, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex
				continue
			}
			if ch == "[" {
				depth += 1
			} else if ch == "]" {
				depth -= 1
				if depth == 0 {
					closeBracket = idx
					break
				}
			}
			idx = input.index(after: idx)
		}
		guard let closeBracket else {
			return nil
		}
		let openParen = input.index(after: closeBracket)
		guard openParen < input.endIndex, input[openParen] == "(" else {
			return nil
		}
		var parenDepth = 0
		var destIdx = openParen
		var closeParen: String.Index?
		while destIdx < input.endIndex {
			let ch = input[destIdx]
			if ch == "\\" {
				destIdx = input.index(destIdx, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex
				continue
			}
			if ch == "(" {
				parenDepth += 1
			} else if ch == ")" {
				parenDepth -= 1
				if parenDepth == 0 {
					closeParen = destIdx
					break
				}
			}
			destIdx = input.index(after: destIdx)
		}
		guard let closeParen else {
			return nil
		}
		let label = String(input[input.index(after: openBracket)..<closeBracket])
		var rawDest = String(input[input.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespaces)
		// Strip optional title `"title"` after the URL.
		if let space = rawDest.firstIndex(where: \.isWhitespace) {
			rawDest = String(rawDest[..<space])
		}
		if rawDest.hasPrefix("<") && rawDest.hasSuffix(">") && rawDest.count >= 2 {
			rawDest = String(rawDest.dropFirst().dropLast())
		}
		return (label, rawDest, input.index(after: closeParen))
	}

	static func safeDestinationURL(_ string: String, allowDataImage: Bool) -> String? {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			return nil
		}
		let lower = trimmed.lowercased()
		if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
			return trimmed
		}
		if allowDataImage && lower.hasPrefix("data:image/") {
			return trimmed
		}
		return nil
	}

	static func linkifyPlainText(_ line: String) -> String {
		guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
			return line.escapingSpecialXMLCharacters
		}
		let nsRange = NSRange(line.startIndex..., in: line)
		let matches = detector.matches(in: line, range: nsRange)
		guard !matches.isEmpty else {
			return line.escapingSpecialXMLCharacters
		}
		var result = ""
		var cursor = line.startIndex
		for match in matches {
			guard let range = Range(match.range, in: line),
				  let url = match.url,
				  let scheme = url.scheme?.lowercased(),
				  scheme == "http" || scheme == "https" || scheme == "mailto" else {
				continue
			}
			result += String(line[cursor..<range.lowerBound]).escapingSpecialXMLCharacters
			let matchedText = String(line[range])
			result += "<a href=\"\(url.absoluteString.escapingSpecialXMLCharacters)\">\(matchedText.escapingSpecialXMLCharacters)</a>"
			cursor = range.upperBound
		}
		result += String(line[cursor...]).escapingSpecialXMLCharacters
		return result
	}

	static func stripInlineMarkdown(_ text: String) -> String {
		var s = text
		s = s.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
		s = s.replacingOccurrences(of: #"(\*\*|__|~~|\*|_|\`)"#, with: "", options: .regularExpression)
		return s.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	static func defaultTitle(from blocks: [Block]) -> String? {
		for block in blocks {
			switch block {
			case .heading(_, let text), .paragraph(let text):
				let clean = stripInlineMarkdown(text).replacingOccurrences(of: "\n", with: " ")
				if !clean.isEmpty {
					return String(clean.prefix(100))
				}
			case .list(_, let items):
				if let first = items.first {
					let clean = stripInlineMarkdown(first.content)
					if !clean.isEmpty {
						return String(clean.prefix(100))
					}
				}
			default:
				continue
			}
		}
		return nil
	}

	static func makeExcerpt(from blocks: [Block]) -> String? {
		var parts = [String]()
		for block in blocks {
			switch block {
			case .paragraph(let text), .heading(_, let text):
				let clean = stripInlineMarkdown(text)
				if !clean.isEmpty {
					parts.append(clean)
				}
			case .blockquote(let inner):
				if let innerExcerpt = makeExcerpt(from: inner) {
					parts.append(innerExcerpt)
				}
			case .list(_, let items):
				for item in items.prefix(3) {
					let clean = stripInlineMarkdown(item.content)
					if !clean.isEmpty {
						parts.append(clean)
					}
				}
			default:
				break
			}
			if parts.joined(separator: " ").count >= 260 {
				break
			}
		}
		return excerpt(fromPlainText: parts.joined(separator: " "))
	}

	static func excerpt(fromPlainText text: String) -> String? {
		let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
		guard !collapsed.isEmpty else {
			return nil
		}
		if collapsed.count <= 240 {
			return collapsed
		}
		return String(collapsed.prefix(240)).trimmingCharacters(in: .whitespaces) + "…"
	}

	static func nonEmpty(_ value: String?) -> String? {
		guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}
}
