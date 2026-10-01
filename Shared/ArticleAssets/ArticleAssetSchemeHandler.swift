//
//  ArticleAssetSchemeHandler.swift
//  NetNewsList
//
//  Serves nnlasset:// images to the article view: the stored copy when there is
//  one, otherwise a download that is then stored, otherwise (offline, or the site
//  refuses) a small placeholder.
//

import Foundation
import WebKit
import RSWeb

@MainActor final class ArticleAssetSchemeHandler: NSObject, WKURLSchemeHandler {

	static let shared = ArticleAssetSchemeHandler()

	private var stoppedTasks = Set<ObjectIdentifier>()

	private static let placeholder = Data("""
	<svg xmlns="http://www.w3.org/2000/svg" width="240" height="135" viewBox="0 0 240 135"><rect width="240" height="135" rx="6" fill="#8884"/><path d="M96 88l18-22 13 15 9-10 18 17z" fill="#8888"/><circle cx="104" cy="56" r="7" fill="#8888"/></svg>
	""".utf8)

	func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
		guard let url = urlSchemeTask.request.url, let asset = ArticleImageRewriter.parse(assetURL: url) else {
			urlSchemeTask.didFailWithError(URLError(.badURL))
			return
		}
		let taskID = ObjectIdentifier(urlSchemeTask)
		let pageURL = webView.url?.scheme?.hasPrefix("http") == true ? webView.url?.absoluteString : nil
		let userAgent = UserAgent.browserUserAgent
		Task { @MainActor in
			let data = await ArticleAssetStore.shared.imageData(articleID: asset.articleID, originalURL: asset.originalURL, pageURL: pageURL, userAgent: userAgent, download: true)
			guard self.stoppedTasks.remove(taskID) == nil else {
				return
			}
			let body = data ?? Self.placeholder
			let mimeType = data.map(ArticleAssetStore.mimeType(for:)) ?? "image/svg+xml"
			let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: body.count, textEncodingName: nil)
			urlSchemeTask.didReceive(response)
			urlSchemeTask.didReceive(body)
			urlSchemeTask.didFinish()
		}
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
		// WebKit forbids answering a task after it has been stopped.
		stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
	}
}
