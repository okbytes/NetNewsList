//
//  PageFetcher.swift
//  Extraction
//
//  One GET for one saved page. Deliberately not RSWeb’s Downloader, which caches
//  error responses and would hand Retry the same failure. See
//  Technotes/NetNewsList/Plan.md, D3.
//

import Foundation

public struct FetchedPage: Sendable, Equatable {
	/// The address after redirects.
	public let url: URL
	public let html: String
}

public struct PageFetcher: Sendable {

	public static let maximumBytes = 5 * 1024 * 1024
	public static let timeout: TimeInterval = 20

	private let configure: @Sendable (URLSessionConfiguration) -> Void

	/// `configure` lets tests install a URLProtocol.
	public init(configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }) {
		self.configure = configure
	}

	public func fetch(_ url: URL, userAgent: String?) async throws -> FetchedPage {
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			throw ExtractionError.unsupportedURL
		}

		// A fresh ephemeral session per page: no cookies or cache carry over between saves.
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = Self.timeout
		configuration.timeoutIntervalForResource = Self.timeout
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configure(configuration)
		let session = URLSession(configuration: configuration)
		defer {
			session.finishTasksAndInvalidate()
		}

		var request = URLRequest(url: url)
		request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
		if let language = Locale.preferredLanguages.first {
			request.setValue("\(language),en;q=0.8", forHTTPHeaderField: "Accept-Language")
		}
		if let userAgent {
			request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		}

		let (bytes, response) = try await session.bytes(for: request)
		if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
			throw ExtractionError.httpStatus(httpResponse.statusCode)
		}
		if let mimeType = response.mimeType?.lowercased(), !Self.isHTML(mimeType) {
			throw ExtractionError.notHTML(mimeType)
		}
		if response.expectedContentLength > Int64(Self.maximumBytes) {
			throw ExtractionError.tooLarge
		}

		var data = Data()
		data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Int64(Self.maximumBytes)))))
		for try await byte in bytes {
			data.append(byte)
			if data.count > Self.maximumBytes {
				throw ExtractionError.tooLarge
			}
		}

		guard let html = Self.decode(data, textEncodingName: response.textEncodingName) else {
			throw ExtractionError.undecodable
		}
		return FetchedPage(url: response.url ?? url, html: html)
	}
}

extension PageFetcher {

	static func isHTML(_ mimeType: String) -> Bool {
		mimeType == "text/html" || mimeType == "application/xhtml+xml"
	}

	/// Decodes a page using, in order, the HTTP charset, a `<meta>` charset and UTF-8,
	/// falling back to Windows-1252, which accepts any byte sequence.
	static func decode(_ data: Data, textEncodingName: String?) -> String? {
		for name in [textEncodingName, sniffedCharset(in: data)].compactMap({ $0 }) {
			if let encoding = encoding(named: name), let string = String(data: data, encoding: encoding) {
				return string
			}
		}
		if let string = String(data: data, encoding: .utf8) {
			return string
		}
		return String(data: data, encoding: .windowsCP1252)
	}

	static func encoding(named name: String) -> String.Encoding? {
		let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name.trimmingCharacters(in: .whitespaces) as CFString)
		guard cfEncoding != kCFStringEncodingInvalidId else {
			return nil
		}
		return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
	}

	/// Looks for `<meta charset>` or an `http-equiv` content type in the first 4 KB.
	static func sniffedCharset(in data: Data) -> String? {
		let prefix = String(decoding: data.prefix(4096), as: Unicode.ASCII.self).lowercased()
		guard let range = prefix.range(of: #"<meta[^>]*charset\s*=\s*["']?\s*([a-z0-9_\-:.]+)"#, options: .regularExpression) else {
			return nil
		}
		let match = prefix[range]
		guard let charsetRange = match.range(of: #"charset\s*=\s*["']?\s*"#, options: .regularExpression) else {
			return nil
		}
		let charset = match[charsetRange.upperBound...].prefix { character in
			character.isLetter || character.isNumber || "_-:.".contains(character)
		}
		return charset.isEmpty ? nil : String(charset)
	}
}
