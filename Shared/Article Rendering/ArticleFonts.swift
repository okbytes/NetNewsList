//
//  ArticleFonts.swift
//  NetNewsList
//
//  Article body text is set in Breve (DSType Foundry): Breve Text on the Mac and
//  Breve News (cut for narrow columns) on the iPhone; titles, headings and
//  everything else keep the system font.
//
//  The installed Breve files name each style as a family of its own, so CSS can't
//  ask for "Breve Text" bold. These @font-face rules gather the styles into the
//  body family stylesheet.css uses. A Mac finds them
//  among its installed fonts by PostScript name. The iOS app carries the faces put
//  in the git-ignored iOS/Resources/ArticleFonts/ and inlines them as data: URLs,
//  since WebKit blocks fonts from a custom URL scheme on an https page as mixed
//  content. Without Breve, articles fall back to the system font.
//

import Foundation

enum ArticleFonts {

	static let css: String = faces.map(\.css).joined(separator: "\n")

	private struct Face {

		let family: String
		let style: String
		let weight: Int
		let italic: Bool

		/// "BreveText-SemiBoldItalic"
		var postScriptName: String {
			"\(family.replacing(" ", with: ""))-\(style.replacing(" ", with: ""))\(italic ? "Italic" : "")"
		}

		/// "Breve Text Semi Bold Italic"
		var fileName: String {
			"\(family) \(style)\(italic ? " Italic" : "")"
		}

		var css: String {
			var sources = ["local(\"\(postScriptName)\")"]
			if let bundled = bundledSource {
				sources.append(bundled)
			}
			return """
			@font-face {
				font-family: "\(family)";
				src: \(sources.joined(separator: ", "));
				font-weight: \(weight);
				font-style: \(italic ? "italic" : "normal");
			}
			"""
		}

		private var bundledSource: String? {
			for (fileExtension, mimeType) in [("otf", "font/otf"), ("ttf", "font/ttf")] {
				if let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension),
				   let data = try? Data(contentsOf: url) {
					return "url(data:\(mimeType);base64,\(data.base64EncodedString()))"
				}
			}
			return nil
		}
	}

	private static let faces: [Face] = {
		let styles = [("Light", 300), ("Book", 400), ("Medium", 500), ("Semi Bold", 600), ("Bold", 700), ("Black", 900)]
		#if os(iOS)
		let family = "Breve News"
		#else
		let family = "Breve Text"
		#endif

		return styles.flatMap { style, weight in
			[false, true].map { italic in
				Face(family: family, style: style, weight: weight, italic: italic)
			}
		}
	}()
}
