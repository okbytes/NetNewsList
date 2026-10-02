import AppKit
import Extraction

// Usage: extract-page [--live] [--html] URL...
// Prints one line per URL: OK (readable), THIN (too little text) or FAIL, with timing and metadata.
// --live loads the page with its JavaScript on first (the app's "Retry with Live Page").
// --html also prints the extracted HTML.

let arguments = CommandLine.arguments.dropFirst()
let urls = arguments.filter { !$0.hasPrefix("--") }
let usesLivePage = arguments.contains("--live")
let printsHTML = arguments.contains("--html")
let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

@MainActor func run() async {
	_ = NSApplication.shared
	let fetcher = PageFetcher()
	let extractor = ReadabilityWebExtractor()
	for string in urls {
		guard let url = URL(string: string) else {
			print("FAIL not a URL | \(string)")
			continue
		}
		let start = Date()
		do {
			let page: ExtractedPage
			if usesLivePage {
				page = try await extractor.extractLivePage(url: url, userAgent: userAgent)
			} else {
				let fetched = try await fetcher.fetch(url, userAgent: userAgent)
				page = try await extractor.extract(html: fetched.html, url: fetched.url)
			}
			let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
			let verdict = page.hasReadableContent ? "OK  " : "THIN"
			print("\(verdict) \(elapsed) chars=\(page.textLength) title=\(page.title ?? "-") | byline=\(page.byline ?? "-") | site=\(page.siteName ?? "-") | published=\(page.publishedTime ?? "-") | \(string)")
			if printsHTML {
				print(page.contentHTML ?? "(no content)")
			}
		} catch {
			let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
			print("FAIL \(elapsed) \(error.localizedDescription) | \(string)")
		}
	}
	exit(0)
}

Task { @MainActor in
	await run()
}
RunLoop.main.run()
