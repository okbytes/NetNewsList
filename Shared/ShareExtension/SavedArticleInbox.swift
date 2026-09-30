//
//  SavedArticleInbox.swift
//  NetNewsList
//
//  The app-group folder where share extensions leave SavedArticleRequests: one
//  property list per request, so a writer never rewrites another’s request.
//

import Foundation
import os
import RSCore

enum SavedArticleInbox {

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "SavedArticleInbox")
	private static let fileExtension = "plist"

	/// `<app group>/Inbox`, or nil when the app group is unavailable (a signing
	/// mismatch between the entitlements and the AppGroup Info.plist key).
	static let directoryURL: URL? = {
		guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String,
			  let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
			logger.error("SavedArticleInbox: the app group container is unavailable, so shared pages can’t reach the app")
			return nil
		}
		let directoryURL = containerURL.appendingPathComponent("Inbox", isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
		} catch {
			logger.error("SavedArticleInbox: couldn’t create the inbox: \(error.localizedDescription, privacy: .public)")
			return nil
		}
		return directoryURL
	}()

	static func add(_ request: SavedArticleRequest) throws {
		guard let directoryURL else {
			throw CocoaError(.fileNoSuchFile)
		}
		// Names sort by time, so the app saves pages in the order they were shared.
		let name = String(format: "%.0f-%@", request.dateRequested.timeIntervalSince1970 * 1000, UUID().uuidString)
		let fileURL = directoryURL.appendingPathComponent(name).appendingPathExtension(fileExtension)
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		let data = try encoder.encode(request)

		var coordinationError: NSError?
		var writeError: (any Error)?
		NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
			do {
				try data.write(to: url, options: .atomic)
			} catch {
				writeError = error
			}
		}
		if let error = coordinationError ?? writeError {
			logger.error("SavedArticleInbox: couldn’t write a request: \(error.localizedDescription, privacy: .public)")
			throw error
		}
	}

	/// The waiting requests, oldest first.
	static func requestFileURLs() -> [URL] {
		guard let directoryURL,
			  let fileURLs = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
			return []
		}
		return fileURLs.filter { $0.pathExtension == fileExtension }.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	static func request(at fileURL: URL) -> SavedArticleRequest? {
		var coordinationError: NSError?
		var request: SavedArticleRequest?
		NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
			if let data = try? Data(contentsOf: url) {
				request = try? PropertyListDecoder().decode(SavedArticleRequest.self, from: data)
			}
		}
		return request
	}

	static func remove(_ fileURL: URL) {
		var coordinationError: NSError?
		NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { url in
			try? FileManager.default.removeItem(at: url)
		}
	}
}
