//
//  ArticleAssetStore.swift
//  NetNewsList
//
//  Local copies of saved articles’ images, so they show offline. One folder per
//  article in Application Support (not Caches, which CacheCleaner and the system
//  empty), never backed up and never synced: each device downloads its own.
//  See Technotes/NetNewsList/Plan.md, 3.3.
//

import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os
import RSCore

actor ArticleAssetStore {

	static let shared = ArticleAssetStore()

	static let maximumImagesPerArticle = 40
	static let maximumBytesPerArticle = 25 * 1024 * 1024
	static let maximumPixelSize = 1600
	private static let maximumConcurrentDownloads = 4
	private static let timeout: TimeInterval = 20

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleAssetStore")

	nonisolated let rootURL: URL
	private let session: URLSession
	private var downloads = [String: Task<Data?, Never>]()

	init() {
		let applicationSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
		var rootURL = applicationSupport.appendingPathComponent("NetNewsList", isDirectory: true).appendingPathComponent("ArticleAssets", isDirectory: true)
		try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
		var resourceValues = URLResourceValues()
		resourceValues.isExcludedFromBackup = true
		try? rootURL.setResourceValues(resourceValues)
		self.rootURL = rootURL

		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = Self.timeout
		configuration.timeoutIntervalForResource = Self.timeout
		configuration.httpMaximumConnectionsPerHost = Self.maximumConcurrentDownloads
		self.session = URLSession(configuration: configuration)
	}

	// MARK: - API

	/// The image for an original URL: the stored copy, or, when `download` is true,
	/// a fresh download that is then stored.
	func imageData(articleID: String, originalURL: String, pageURL: String?, userAgent: String?, download: Bool) async -> Data? {
		let fileURL = fileURL(articleID: articleID, originalURL: originalURL)
		if let data = try? Data(contentsOf: fileURL) {
			return data
		}
		guard download else {
			return nil
		}
		return await downloadAndStore(articleID: articleID, originalURL: originalURL, pageURL: pageURL, userAgent: userAgent)
	}

	/// Downloads the article’s images that aren’t stored yet, within the per-article limits.
	func prefetch(articleID: String, html: String, pageURL: String?, userAgent: String?) async {
		let baseURL = pageURL.flatMap { URL(string: $0) }
		let imageURLs = ArticleImageRewriter.imageURLs(in: html, baseURL: baseURL).prefix(Self.maximumImagesPerArticle)
		let missing = imageURLs.filter { !FileManager.default.fileExists(atPath: fileURL(articleID: articleID, originalURL: $0).path) }
		guard !missing.isEmpty else {
			return
		}

		var index = missing.startIndex
		await withTaskGroup(of: Void.self) { group in
			var running = 0
			while index < missing.endIndex || running > 0 {
				while running < Self.maximumConcurrentDownloads, index < missing.endIndex {
					let originalURL = missing[index]
					index = missing.index(after: index)
					guard storedBytes(articleID: articleID) < Self.maximumBytesPerArticle else {
						index = missing.endIndex
						break
					}
					running += 1
					group.addTask {
						_ = await self.downloadAndStore(articleID: articleID, originalURL: originalURL, pageURL: pageURL, userAgent: userAgent)
					}
				}
				if running > 0 {
					await group.next()
					running -= 1
				}
			}
		}
	}

	func deleteAssets(articleIDs: Set<String>) {
		for articleID in articleIDs {
			try? FileManager.default.removeItem(at: directoryURL(articleID: articleID))
		}
	}

	/// The articles that have a folder of images.
	func storedArticleIDs() -> Set<String> {
		let folders = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
		return Set(folders.filter { !$0.hasPrefix(".") })
	}

	nonisolated func directoryURL(articleID: String) -> URL {
		rootURL.appendingPathComponent(articleID, isDirectory: true)
	}

	nonisolated func fileURL(articleID: String, originalURL: String) -> URL {
		let digest = SHA256.hash(data: Data(originalURL.utf8))
		let name = digest.map { String(format: "%02x", $0) }.joined()
		return directoryURL(articleID: articleID).appendingPathComponent(name)
	}

	/// A content type for stored image data, from its first bytes.
	nonisolated static func mimeType(for data: Data) -> String {
		let bytes = [UInt8](data.prefix(12))
		if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
			return "image/jpeg"
		}
		if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
			return "image/png"
		}
		if bytes.starts(with: [0x47, 0x49, 0x46]) {
			return "image/gif"
		}
		if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
			return "image/webp"
		}
		if let prefix = String(data: data.prefix(256), encoding: .utf8), prefix.contains("<svg") {
			return "image/svg+xml"
		}
		return "application/octet-stream"
	}
}

extension ArticleAssetStore {

	/// Images wider or taller than 1600 pixels are stored at 1600; animated GIFs and
	/// vector images are kept as they are.
	nonisolated static func downsampledIfLarge(_ data: Data) -> Data {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
			  let type = CGImageSourceGetType(source),
			  CGImageSourceGetCount(source) == 1,
			  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = properties[kCGImagePropertyPixelWidth] as? Int,
			  let height = properties[kCGImagePropertyPixelHeight] as? Int,
			  max(width, height) > maximumPixelSize else {
			return data
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
		]
		guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
			return data
		}
		let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(thumbnail.alphaInfo)
		let outputType = hasAlpha ? UTType.png.identifier : (type as String == UTType.png.identifier ? UTType.png.identifier : UTType.jpeg.identifier)
		let output = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(output, outputType as CFString, 1, nil) else {
			return data
		}
		CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
		guard CGImageDestinationFinalize(destination) else {
			return data
		}
		return output as Data
	}
}

private extension ArticleAssetStore {

	func downloadAndStore(articleID: String, originalURL: String, pageURL: String?, userAgent: String?) async -> Data? {
		let key = "\(articleID)/\(originalURL)"
		if let download = downloads[key] {
			return await download.value
		}
		let download = Task {
			await self.fetchAndStore(articleID: articleID, originalURL: originalURL, pageURL: pageURL, userAgent: userAgent)
		}
		downloads[key] = download
		let data = await download.value
		downloads[key] = nil
		return data
	}

	func fetchAndStore(articleID: String, originalURL: String, pageURL: String?, userAgent: String?) async -> Data? {
		guard let url = URL(string: originalURL) else {
			return nil
		}
		// Some sites refuse images without the page as the referrer, others refuse them with it.
		var data = await fetch(url, referrer: pageURL, userAgent: userAgent)
		if data == nil, pageURL != nil {
			data = await fetch(url, referrer: nil, userAgent: userAgent)
		}
		guard let data, !data.isEmpty else {
			return nil
		}
		let stored = Self.downsampledIfLarge(data)
		let fileURL = fileURL(articleID: articleID, originalURL: originalURL)
		do {
			try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try stored.write(to: fileURL, options: .atomic)
		} catch {
			Self.logger.error("ArticleAssetStore: couldn’t store an image: \(error.localizedDescription, privacy: .public)")
		}
		return stored
	}

	func fetch(_ url: URL, referrer: String?, userAgent: String?) async -> Data? {
		var request = URLRequest(url: url)
		request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
		if let referrer {
			request.setValue(referrer, forHTTPHeaderField: "Referer")
		}
		if let userAgent {
			request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		}
		guard let (data, response) = try? await session.data(for: request),
			  let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
			return nil
		}
		if let mimeType = httpResponse.mimeType?.lowercased(), !mimeType.hasPrefix("image/"), mimeType != "application/octet-stream" {
			return nil
		}
		return data
	}

	func storedBytes(articleID: String) -> Int {
		let folder = directoryURL(articleID: articleID)
		let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
		return files.reduce(0) { total, file in
			total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		}
	}
}
