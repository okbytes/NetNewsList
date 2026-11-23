//
//  SavedArticleRequestProcessor.swift
//  NetNewsList
//
//  Saves the pages the share extensions left in the app-group inbox. Runs at
//  launch, whenever a new request appears while the app is running, on
//  foreground and in the iOS background refresh task.
//

import Foundation
import os
import UniformTypeIdentifiers
import RSCore
import Account
import Extraction

final class SavedArticleRequestProcessor: NSObject, NSFilePresenter, Sendable {

	static let shared = SavedArticleRequestProcessor()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "SavedArticleRequestProcessor")

	private let operationQueue: OperationQueue = {
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		return queue
	}()

	private struct State {
		var isPresenting = false
	}
	private let state = OSAllocatedUnfairLock(initialState: State())

	var presentedItemURL: URL? {
		SavedArticleInbox.directoryURL
	}

	var presentedItemOperationQueue: OperationQueue {
		operationQueue
	}

	/// Starts watching the inbox and saves what is already there.
	func start() {
		resume()
	}

	func resume() {
		let shouldAdd = state.withLock { state -> Bool in
			guard !state.isPresenting else {
				return false
			}
			state.isPresenting = true
			return true
		}
		if shouldAdd, presentedItemURL != nil {
			NSFileCoordinator.addFilePresenter(self)
		}
		Task { @MainActor in
			await RequestQueue.shared.processInbox()
		}
	}

	func suspend() {
		let shouldRemove = state.withLock { state -> Bool in
			guard state.isPresenting else {
				return false
			}
			state.isPresenting = false
			return true
		}
		if shouldRemove {
			NSFileCoordinator.removeFilePresenter(self)
		}
	}

	/// Saves everything in the inbox now. For the iOS background refresh task.
	@MainActor func processInbox() async {
		await RequestQueue.shared.processInbox()
	}

	// MARK: - NSFilePresenter

	func presentedSubitemDidAppear(at url: URL) {
		scheduleProcessing()
	}

	func presentedSubitemDidChange(at url: URL) {
		scheduleProcessing()
	}

	func presentedItemDidChange() {
		scheduleProcessing()
	}
}

private extension SavedArticleRequestProcessor {

	func scheduleProcessing() {
		Task { @MainActor in
			await RequestQueue.shared.processInbox()
		}
	}

	/// Serializes processing on the main actor so a request is never saved twice.
	@MainActor final class RequestQueue {

		static let shared = RequestQueue()
		private var isProcessing = false
		private var needsAnotherPass = false

		func processInbox() async {
			guard !isProcessing else {
				needsAnotherPass = true
				return
			}
			isProcessing = true
			defer {
				isProcessing = false
			}
			repeat {
				needsAnotherPass = false
				for fileURL in SavedArticleInbox.requestFileURLs() {
					await process(fileURL)
				}
			} while needsAnotherPass
		}

		func process(_ fileURL: URL) async {
			// Remove first: a request that fails is reported, not retried forever.
			let request = SavedArticleInbox.request(at: fileURL)
			SavedArticleInbox.remove(fileURL)
			guard let request else {
				SavedArticleRequestProcessor.logger.error("SavedArticleRequestProcessor: skipped an unreadable request \(fileURL.lastPathComponent, privacy: .public)")
				return
			}
			let stagedFileURL = request.importedFileName.flatMap { SavedArticleInbox.importedFileURL(named: $0) }
			defer {
				if let stagedFileURL {
					SavedArticleInbox.remove(stagedFileURL)
				}
			}
			do {
				if let url = request.url {
					try await ExtractionCoordinator.shared.saveArticle(url: url, title: request.title, body: request.body, dateSaved: request.dateRequested)
					SavedArticleRequestProcessor.logger.info("SavedArticleRequestProcessor: saved \(url, privacy: .public)")
				} else if let stagedFileURL {
					let contentType = request.contentTypeIdentifier.flatMap { UTType($0) }
					if contentType?.conforms(to: .rtfd) == true || stagedFileURL.pathExtension.lowercased() == "rtfd" {
						try await ExtractionCoordinator.shared.importFile(at: stagedFileURL, title: request.title, dateSaved: request.dateRequested)
					} else if let contentType {
						let data = try Data(contentsOf: stagedFileURL)
						try await ExtractionCoordinator.shared.importData(data, contentType: contentType, fileName: stagedFileURL.lastPathComponent, title: request.title, dateSaved: request.dateRequested)
					} else {
						try await ExtractionCoordinator.shared.importFile(at: stagedFileURL, title: request.title, dateSaved: request.dateRequested)
					}
					SavedArticleRequestProcessor.logger.info("SavedArticleRequestProcessor: imported staged file \(stagedFileURL.lastPathComponent, privacy: .public)")
				} else if let body = request.body {
					let contentType = request.contentTypeIdentifier.flatMap { UTType($0) }
					if contentType?.conforms(to: .html) == true {
						try await ExtractionCoordinator.shared.importHTML(body, title: request.title, dateSaved: request.dateRequested)
					} else {
						try await ExtractionCoordinator.shared.importText(body, title: request.title, dateSaved: request.dateRequested)
					}
					SavedArticleRequestProcessor.logger.info("SavedArticleRequestProcessor: imported shared text")
				} else {
					SavedArticleRequestProcessor.logger.error("SavedArticleRequestProcessor: request had neither URL nor content")
				}
			} catch {
				SavedArticleRequestProcessor.logger.error("SavedArticleRequestProcessor: couldn’t process request: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
}
