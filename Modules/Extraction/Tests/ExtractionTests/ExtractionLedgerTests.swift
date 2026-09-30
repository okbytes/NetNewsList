//
//  ExtractionLedgerTests.swift
//  ExtractionTests
//

import Foundation
import Testing
@testable import Extraction

struct ExtractionLedgerTests {

	private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

	@Test func newArticleMayBeTriedAtOnce() {
		#expect(ExtractionLedger().allowsAutomaticAttempt(for: "a", at: start))
	}

	@Test func failuresBackOffThenStop() {
		var ledger = ExtractionLedger()
		ledger.recordFailure(for: "a", message: "403", at: start)
		#expect(!ledger.allowsAutomaticAttempt(for: "a", at: start.addingTimeInterval(30)))
		#expect(ledger.allowsAutomaticAttempt(for: "a", at: start.addingTimeInterval(61)))

		ledger.recordFailure(for: "a", message: "403", at: start.addingTimeInterval(61))
		#expect(!ledger.allowsAutomaticAttempt(for: "a", at: start.addingTimeInterval(300)))
		#expect(ledger.allowsAutomaticAttempt(for: "a", at: start.addingTimeInterval(700)))

		ledger.recordFailure(for: "a", message: "timed out", at: start.addingTimeInterval(700))
		#expect(!ledger.allowsAutomaticAttempt(for: "a", at: start.addingTimeInterval(1_000_000)))
		#expect(ledger.failureMessage(for: "a") == "timed out")
		#expect(ledger.entries["a"]?.attempts == 3)
	}

	@Test func removingAllowsATryAgain() {
		var ledger = ExtractionLedger()
		for offset in 0..<3 {
			ledger.recordFailure(for: "a", message: "x", at: start.addingTimeInterval(Double(offset)))
		}
		ledger.remove("a")
		#expect(ledger.allowsAutomaticAttempt(for: "a", at: start))
		#expect(ledger.failureMessage(for: "a") == nil)
	}

	@Test func pruneKeepsOnlyPendingArticles() {
		var ledger = ExtractionLedger()
		ledger.recordFailure(for: "a", message: "x", at: start)
		ledger.recordFailure(for: "b", message: "y", at: start)
		ledger.prune(keeping: ["b", "c"])
		#expect(ledger.entries.keys.sorted() == ["b"])
	}

	@Test func roundTripsThroughAFile() throws {
		var ledger = ExtractionLedger()
		ledger.recordFailure(for: "a", message: "x", at: start)
		let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
		defer {
			try? FileManager.default.removeItem(at: fileURL)
		}
		try ledger.save(to: fileURL)
		#expect(ExtractionLedger.load(from: fileURL) == ledger)
		#expect(ExtractionLedger.load(from: fileURL.appendingPathExtension("missing")) == ExtractionLedger())
	}
}
