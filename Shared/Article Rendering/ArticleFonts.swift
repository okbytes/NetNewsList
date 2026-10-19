//
//  ArticleFonts.swift
//  NetNewsList
//
//  Article text is set in Breve (DSType Foundry): Breve Text for the body on the
//  Mac, Breve News (cut for narrow columns) for the body on the iPhone, and Breve
//  Title for headlines; everything else keeps the system font.
//
//  The installed Breve files name each style as a family of its own, so CSS can't
//  ask for "Breve Text" bold. These @font-face rules gather the styles into the
//  body and "Breve Title" families stylesheet.css uses. A Mac finds them
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
		let textStyles = [("Light", 300), ("Book", 400), ("Medium", 500), ("Semi Bold", 600), ("Bold", 700), ("Black", 900)]
		let titleStyles = [("Thin", 100), ("Extra Light", 200)] + textStyles
		#if os(iOS)
		let bodyFamily = "Breve News"
		#else
		let bodyFamily = "Breve Text"
		#endif
		let families = [(bodyFamily, textStyles), ("Breve Title", titleStyles)]

		return families.flatMap { family, styles in
			styles.flatMap { style, weight in
				[false, true].map { italic in
					Face(family: family, style: style, weight: weight, italic: italic)
				}
			}
		}
	}()
}
