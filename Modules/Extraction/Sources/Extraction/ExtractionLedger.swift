//
//  ExtractionLedger.swift
//  Extraction
//
//  Local, per-device record of failed extraction attempts. It decides when a
//  pending article may be tried again automatically and what error to show.
//  It never syncs: each device keeps its own. See Technotes/NetNewsList/Plan.md, D2.
//

import Foundation

public struct ExtractionLedger: Codable, Sendable, Equatable {

	public struct Entry: Codable, Sendable, Equatable {
		public var attempts: Int
		public var lastAttempt: Date
		public var lastError: String
	}

	/// After this many failures an article waits for a manual Retry.
	public static let maximumAutomaticAttempts = 3

	/// How long to wait before the next automatic attempt, indexed by failures so far.
	static let retryDelays: [TimeInterval] = [0, 60, 600]

	public private(set) var entries = [String: Entry]()

	public init() {
	}

	public func failureMessage(for articleID: String) -> String? {
		entries[articleID]?.lastError
	}

	public func allowsAutomaticAttempt(for articleID: String, at date: Date) -> Bool {
		guard let entry = entries[articleID] else {
			return true
		}
		guard entry.attempts < Self.maximumAutomaticAttempts else {
			return false
		}
		let delay = Self.retryDelays[min(entry.attempts, Self.retryDelays.count - 1)]
		return date.timeIntervalSince(entry.lastAttempt) >= delay
	}

	public mutating func recordFailure(for articleID: String, message: String, at date: Date) {
		var entry = entries[articleID] ?? Entry(attempts: 0, lastAttempt: date, lastError: message)
		entry.attempts += 1
		entry.lastAttempt = date
		entry.lastError = message
		entries[articleID] = entry
	}

	public mutating func remove(_ articleID: String) {
		entries[articleID] = nil
	}

	/// Forgets articles that are no longer pending: extracted elsewhere, or deleted.
	public mutating func prune(keeping pendingArticleIDs: Set<String>) {
		entries = entries.filter { pendingArticleIDs.contains($0.key) }
	}

	public static func load(from fileURL: URL) -> ExtractionLedger {
		guard let data = try? Data(contentsOf: fileURL),
			  let ledger = try? JSONDecoder().decode(ExtractionLedger.self, from: data) else {
			return ExtractionLedger()
		}
		return ledger
	}

	public func save(to fileURL: URL) throws {
		let data = try JSONEncoder().encode(self)
		try data.write(to: fileURL, options: .atomic)
	}
}
