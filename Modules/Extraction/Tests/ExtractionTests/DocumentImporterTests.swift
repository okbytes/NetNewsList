//
//  DocumentImporterTests.swift
//  ExtractionTests
//

import Foundation
import Testing
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics
@testable import Extraction

@Suite struct MarkdownConverterTests {

	@Test func convertsHeadingsFrontmatterListsTablesCodeAndInline() throws {
		let md = """
		---
		title: Frontmatter Title
		author: Jane Doe
		---

		# Frontmatter Title

		Intro with **bold**, *italic*, ~~strike~~, `code`, and [a link](https://example.com/a).

		## Section Two

		> A quoted line.

		- First item
		- [x] Done task
		- [ ] Open task

		```swift
		let x = 1 < 2
		```

		| Name | Value |
		| :--- | ---: |
		| Alpha | 42 |
		"""

		let doc = try MarkdownConverter.convert(md)
		#expect(doc.title == "Frontmatter Title")
		#expect(doc.byline == "Jane Doe")
		// Leading H1 was extracted as the article title and removed from the body.
		#expect(!doc.contentHTML.contains("<h1>Frontmatter Title</h1>"))
		#expect(doc.contentHTML.contains("<h2>Section Two</h2>"))
		#expect(doc.contentHTML.contains("<strong>bold</strong>"))
		#expect(doc.contentHTML.contains("<em>italic</em>"))
		#expect(doc.contentHTML.contains("<del>strike</del>"))
		#expect(doc.contentHTML.contains("<code>code</code>"))
		#expect(doc.contentHTML.contains("<a href=\"https://example.com/a\">a link</a>"))
		#expect(doc.contentHTML.contains("<blockquote>"))
		#expect(doc.contentHTML.contains("☑ Done task"))
		#expect(doc.contentHTML.contains("☐ Open task"))
		#expect(doc.contentHTML.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
		#expect(doc.contentHTML.contains("<table>"))
		#expect(doc.contentHTML.contains("<td align=\"right\">42</td>"))
	}

	@Test func stripsUnsafeLinkSchemes() throws {
		let md = "# Safe\n\nClick [here](javascript:alert(1)) now."
		let doc = try MarkdownConverter.convert(md)
		#expect(!doc.contentHTML.contains("javascript:"))
		#expect(doc.contentHTML.contains("Click here now."))
	}

	@Test func detectsMarkdownVsPlainText() {
		#expect(MarkdownConverter.looksLikeMarkdown("# Heading\n\nParagraph text"))
		#expect(MarkdownConverter.looksLikeMarkdown("Look at [this](https://example.com) and **bold**."))
		#expect(!MarkdownConverter.looksLikeMarkdown("Just an ordinary sentence.\n\nAnother ordinary paragraph."))
	}

	@Test func plainTextPromotesAppleNotesFirstLineTitle() throws {
		let note = """
		Quarterly Reading Notes

		First paragraph with a link https://example.com/report inside.

		• Bullet one
		• Bullet two
		"""

		let doc = try MarkdownConverter.convertPlainText(note)
		#expect(doc.title == "Quarterly Reading Notes")
		#expect(!doc.contentHTML.contains("Quarterly Reading Notes"))
		#expect(doc.contentHTML.contains("<a href=\"https://example.com/report\">https://example.com/report</a>"))
		#expect(doc.contentHTML.contains("<ul>"))
		#expect(doc.contentHTML.contains("<li>Bullet one</li>"))
	}
}

@MainActor @Suite struct ImportedHTMLAndRTFTests {

	@Test func cleansAppleNotesHTMLAndPromotesHeadings() async throws {
		let extractor = ReadabilityWebExtractor()
		let appleNotesHTML = """
		<div><span style="font-size: 24px"><b>Architecture Notes</b></span></div>
		<div><br></div>
		<div><span style="font-size: 13px">Body text with <span style="font-style: italic">emphasis</span> and <a href="https://example.com">link</a>.</span></div>
		<div><br></div>
		<div><span style="font-size: 18px"><b>Next Steps</b></span></div>
		<ul><li>Item one</li><li>Item two</li></ul>
		<script>alert('xss')</script>
		"""

		let doc = try await DocumentImporter.importHTML(appleNotesHTML) { html in
			try await extractor.cleanImportedHTML(html)
		}

		#expect(doc.title == "Architecture Notes")
		#expect(!doc.contentHTML.contains("<script"))
		#expect(!doc.contentHTML.contains("style="))
		#expect(doc.contentHTML.contains("<h2>Next Steps</h2>"))
		#expect(doc.contentHTML.contains("<em>emphasis</em>"))
		#expect(doc.contentHTML.contains("<li>Item one</li>"))
	}

	@Test func rendersRawMarkdownInsideAppleNotesHTML() async throws {
		let extractor = ReadabilityWebExtractor()
		let rawMarkdownNoteHTML = """
		<div># Migration Guide</div>
		<div><br></div>
		<div>Step one is **very important** with `code`.</div>
		<div><br></div>
		<div>## Details</div>
		<div><br></div>
		<div>- First bullet</div>
		<div>- Second bullet</div>
		"""

		let doc = try await DocumentImporter.importHTML(rawMarkdownNoteHTML) { html in
			try await extractor.cleanImportedHTML(html)
		}

		#expect(doc.title == "Migration Guide")
		#expect(doc.contentHTML.contains("<h2>Details</h2>"))
		#expect(doc.contentHTML.contains("<strong>very important</strong>"))
		#expect(doc.contentHTML.contains("<code>code</code>"))
		#expect(doc.contentHTML.contains("<li>First bullet</li>"))
	}

	@Test func importsRTFData() async throws {
		let attributed = NSMutableAttributedString()
#if canImport(AppKit)
		let headingFont = NSFont.boldSystemFont(ofSize: 24)
		let bodyFont = NSFont.systemFont(ofSize: 13)
		let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
#else
		let headingFont = UIFont.boldSystemFont(ofSize: 24)
		let bodyFont = UIFont.systemFont(ofSize: 13)
		let italicFont = UIFont.italicSystemFont(ofSize: 13)
#endif
		attributed.append(NSAttributedString(string: "Design Memo\n", attributes: [.font: headingFont]))
		attributed.append(NSAttributedString(string: "This is ", attributes: [.font: bodyFont]))
		attributed.append(NSAttributedString(string: "important", attributes: [.font: italicFont]))
		attributed.append(NSAttributedString(string: " text.\n", attributes: [.font: bodyFont]))

		let rtfData = try attributed.data(from: NSRange(location: 0, length: attributed.length),
										  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])

		let doc = try await DocumentImporter.importData(rtfData, contentType: .rtf, fileName: "memo.rtf")
		#expect(doc.title == "Design Memo")
		#expect(doc.contentHTML.contains("<em>important</em>"))
		#expect(doc.contentHTML.contains("This is "))
	}

	@Test func emptyInputThrows() async {
		await #expect(throws: DocumentImportError.self) {
			try await DocumentImporter.importText("   \n  ")
		}
	}
}

@Suite struct PDFDocumentConverterTests {

	@Test func extractsHeadingsParagraphsAndStripsPageNumbers() throws {
		let pdfData = try makeSamplePDF()
		let doc = try PDFDocumentConverter.convert(data: pdfData, fallbackTitle: "Fallback")

		#expect(doc.title == "Annual Report")
		#expect(doc.contentHTML.contains("<h2>Executive Summary</h2>"))
		#expect(doc.contentHTML.contains("hyphenated"))
		#expect(!doc.contentHTML.contains("Running Header"))
		#expect(!doc.contentHTML.contains("<p>1</p>"))
		#expect(!doc.contentHTML.contains("<p>2</p>"))
	}

	@Test func invalidPDFThrowsUnreadablePDF() {
		#expect(throws: DocumentImportError.self) {
			try PDFDocumentConverter.convert(data: Data("not a pdf".utf8))
		}
	}

	private func makeSamplePDF() throws -> Data {
		let pages: [[(String, CGFloat, Bool, CGFloat)]] = [
			[
				("Running Header", 10, false, 750),
				("Annual Report", 24, true, 680),
				("Executive Summary", 16, true, 630),
				("This document contains a hyphen-", 12, false, 590),
				("ated word across two wrapped lines in a paragraph.", 12, false, 572),
				("1", 10, false, 36)
			],
			[
				("Running Header", 10, false, 750),
				("Second page continues the discussion clearly.", 12, false, 680),
				("2", 10, false, 36)
			]
		]

#if canImport(AppKit)
		let data = NSMutableData()
		var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
		guard let consumer = CGDataConsumer(data: data as CFMutableData),
			  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
			throw DocumentImportError.unreadablePDF
		}
		for items in pages {
			context.beginPDFPage(nil)
			let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = graphicsContext
			for (text, size, bold, y) in items {
				let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
				(text as NSString).draw(at: NSPoint(x: 72, y: y), withAttributes: [.font: font])
			}
			NSGraphicsContext.restoreGraphicsState()
			context.endPDFPage()
		}
		context.closePDF()
		return data as Data
#elseif canImport(UIKit)
		let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
		let renderer = UIGraphicsPDFRenderer(bounds: bounds)
		return renderer.pdfData { ctx in
			for items in pages {
				ctx.beginPage()
				for (text, size, bold, y) in items {
					let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
					// UIKit coordinates are top-down; mirror y from the 792pt page height.
					(text as NSString).draw(at: CGPoint(x: 72, y: 792 - y), withAttributes: [.font: font])
				}
			}
		}
#endif
	}
}
