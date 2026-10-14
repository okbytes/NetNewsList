//
//  CloudKitZone+Web.swift
//  CloudKitSync
//
//  CloudKitZone’s operations when the zone reaches iCloud over the web (`webDatabase`).
//  Each CloudKitZone method hands over to its counterpart here, so the zones, their
//  delegates and everything above them run the same code either way. What differs:
//  there are no push subscriptions (the app checks for changes on a timer instead), the
//  change token is CloudKit Web Services’ sync token, kept under its own key, and
//  retries are capped.
//

import Foundation
import CloudKit
import os

/// How many times a web request is tried when iCloud asks to wait or the network fails.
private let webAttemptLimit = 4
private let webNetworkRetryDelay: TimeInterval = 3
/// The longest wait honored between attempts.
private let webMaxRetryDelay: TimeInterval = 60

extension CloudKitZone {

	nonisolated private static var webLogger: Logger {
		cloudKitLogger
	}

	/// The sync token of the last change fetch over the web. Kept apart from the CloudKit
	/// framework’s change token, so switching a copy of the app between the two never hands
	/// one a token from the other.
	var webSyncToken: String? {
		get {
			UserDefaults.standard.string(forKey: webSyncTokenKey)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: webSyncTokenKey)
		}
	}

	var webSyncTokenKey: String {
		"cloudkit.web.token.\(zoneID.zoneName).\(zoneID.ownerName)"
	}

	/// Set while a change fetch is going through the zone from the start (no sync token: a first
	/// sign-in, Reset iCloud Sync, an expired token), until its last page. Such a fetch lists the
	/// zone’s whole history, deletions from long ago included, and a deletion of a record that has
	/// since been saved again here, but not uploaded yet, would delete the new save. So deletions
	/// are ignored until it ends; what it lists is what iCloud has. Kept across launches, so a
	/// fetch cut short resumes the same way.
	var webIsFetchingFromStart: Bool {
		get {
			UserDefaults.standard.bool(forKey: webFetchingFromStartKey)
		}
		set {
			UserDefaults.standard.set(newValue ? true : nil, forKey: webFetchingFromStartKey)
		}
	}

	var webFetchingFromStartKey: String {
		"cloudkit.web.fetchingFromStart.\(zoneID.zoneName).\(zoneID.ownerName)"
	}

	// MARK: - Operations

	func webCreateZoneRecord(_ webDatabase: CloudKitWebDatabase, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
		Task { @MainActor in
			do {
				try await withWebRetries(webDatabase, createsMissingZone: false) {
					try await webDatabase.saveZone(zoneID)
				}
				completion(.success(()))
			} catch {
				completion(.failure(CloudKitError(error)))
			}
		}
	}

	func webQuery(_ webDatabase: CloudKitWebDatabase, _ ckQuery: CKQuery, desiredKeys: [String]?, pageHandler: CloudKitQueryPageHandler?, completion: @escaping (Result<[CKRecord], Error>) -> Void) {
		Task { @MainActor in
			do {
				var records = [CKRecord]()
				var continuationMarker: String?
				repeat {
					let marker = continuationMarker
					let page = try await withWebRetries(webDatabase) {
						try await webDatabase.query(ckQuery, zoneID: zoneID, desiredKeys: desiredKeys, continuationMarker: marker)
					}
					records.append(contentsOf: page.records)
					await pageHandler?(page.records)
					continuationMarker = page.continuationMarker
				} while continuationMarker != nil
				completion(.success(records))
			} catch {
				completion(.failure(CloudKitError(error)))
			}
		}
	}

	func webFetch(_ webDatabase: CloudKitWebDatabase, recordID: CKRecord.ID, completion: @escaping (Result<CKRecord, Error>) -> Void) {
		Task { @MainActor in
			do {
				let results = try await withWebRetries(webDatabase) {
					try await webDatabase.records(for: [recordID])
				}
				switch results[recordID] {
				case .success(let record):
					completion(.success(record))
				case .failure(let error):
					completion(.failure(CloudKitError(error)))
				case nil:
					completion(.failure(CloudKitError(CKError(.unknownItem))))
				}
			} catch {
				completion(.failure(CloudKitError(error)))
			}
		}
	}

	/// Fetches records by ID. A missing record’s result is a CKError `unknownItem`.
	func webRecords(_ webDatabase: CloudKitWebDatabase, for recordIDs: [CKRecord.ID], desiredKeys: [String]?) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
		let results = try await withWebRetries(webDatabase) {
			try await webDatabase.records(for: recordIDs, desiredKeys: desiredKeys)
		}
		return results.mapValues { result in
			result.mapError { $0 as Error }
		}
	}

	func webSaveIfNew(_ webDatabase: CloudKitWebDatabase, _ records: [CKRecord], completion: @escaping (Result<CloudKitUnsavedRecords, Error>) -> Void) {
		Task { @MainActor in
			do {
				var unsaved = try await withWebRetries(webDatabase) {
					try await webDatabase.modify(save: records, delete: [], policy: .ifServerRecordUnchanged, atomic: false)
				}
				if unsaved.values.contains(where: { $0.code == .zoneNotFound }) {
					try await webDatabase.saveZone(zoneID)
					unsaved = try await withWebRetries(webDatabase) {
						try await webDatabase.modify(save: records, delete: [], policy: .ifServerRecordUnchanged, atomic: false)
					}
				}
				for (recordID, error) in unsaved where error.code != .serverRecordChanged {
					Self.webLogger.error("CloudKitZone: saveIfNew did not save \(recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
				}
				completion(.success(unsaved))
			} catch {
				completion(.failure(CloudKitError(error)))
			}
		}
	}

	func webModify(_ webDatabase: CloudKitWebDatabase, recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID], completion: @escaping (Result<Void, Error>) -> Void) {
		Task { @MainActor in
			do {
				var failures = try await withWebRetries(webDatabase) {
					try await webDatabase.modify(save: recordsToSave, delete: recordIDsToDelete, policy: .changedKeys, atomic: true)
				}
				if failures.values.contains(where: { $0.code == .zoneNotFound }) {
					try await webDatabase.saveZone(zoneID)
					failures = try await withWebRetries(webDatabase) {
						try await webDatabase.modify(save: recordsToSave, delete: recordIDsToDelete, policy: .changedKeys, atomic: true)
					}
				}
				guard failures.isEmpty else {
					throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: failures as [AnyHashable: CKError]])
				}
				completion(.success(()))
			} catch {
				completion(.failure(CloudKitError(error)))
			}
		}
	}

	func webDelete(_ webDatabase: CloudKitWebDatabase, ckQuery: CKQuery, pageHandler: CloudKitQueryPageHandler?, completion: @escaping (Result<Void, Error>) -> Void) {
		webQuery(webDatabase, ckQuery, desiredKeys: [], pageHandler: pageHandler) { result in
			switch result {
			case .success(let records):
				self.modify(recordsToSave: [], recordIDsToDelete: records.map(\.recordID), completion: completion)
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}

	/// Fetches the zone’s changes page by page, handing each page to the delegate before
	/// keeping its sync token, so a fetch cut short resumes where it stopped.
	func webFetchChangesInZone(_ webDatabase: CloudKitWebDatabase, completion: @escaping (Result<Void, Error>) -> Void) {
		Task { @MainActor in
			do {
				var didResetExpiredToken = false
				while true {
					let syncToken = webSyncToken
					if syncToken == nil {
						webIsFetchingFromStart = true
					}
					let page: (changed: [CKRecord], deleted: [CloudKitRecordKey], syncToken: String?, moreComing: Bool)
					do {
						page = try await withWebRetries(webDatabase) {
							try await webDatabase.changes(in: zoneID, syncToken: syncToken)
						}
					} catch let error as CKError where error.code == .changeTokenExpired && !didResetExpiredToken {
						Self.webLogger.info("CloudKitZone: \(self.zoneID.zoneName, privacy: .public) sync token expired; fetching everything")
						didResetExpiredToken = true
						webSyncToken = nil
						continue
					}

					if webIsFetchingFromStart && !page.deleted.isEmpty {
						Self.webLogger.info("CloudKitZone: \(self.zoneID.zoneName, privacy: .public) fetching from the start; ignoring \(page.deleted.count) deletions")
					}
					let deleted = webIsFetchingFromStart ? [] : page.deleted.compactMap { key -> CloudKitRecordKey? in
						guard key.recordType.isEmpty else {
							return key
						}
						guard let recordType = webRecordType(forDeletedRecordName: key.recordID.recordName) else {
							Self.webLogger.info("CloudKitZone: \(self.zoneID.zoneName, privacy: .public) ignoring a deletion of unknown type: \(key.recordID.recordName, privacy: .public)")
							return nil
						}
						return CloudKitRecordKey(recordType: recordType, recordID: key.recordID)
					}
					try await delegate?.cloudKitDidModify(changed: page.changed, deleted: deleted)
					if let newToken = page.syncToken {
						webSyncToken = newToken
					}
					fetchChangesPageHandler?(zoneID.zoneName, page.changed.count, deleted.count, page.moreComing)
					if !page.moreComing {
						webIsFetchingFromStart = false
					}
					// A page that says more is coming without a new token would ask for the same page forever.
					guard page.moreComing, page.syncToken != nil, page.syncToken != syncToken else {
						break
					}
				}
				completion(.success(()))
			} catch {
				completion(.failure(CloudKitError(error)))
			}
		}
	}

	// MARK: - Retries

	/// Runs a web request, waiting and trying again when iCloud asks to wait or the network
	/// fails, and creating the zone when it’s missing (as the CloudKit framework path does),
	/// up to `webAttemptLimit` attempts.
	func withWebRetries<T>(_ webDatabase: CloudKitWebDatabase, createsMissingZone: Bool = true, _ operation: () async throws -> T) async throws -> T {
		var attempt = 1
		while true {
			do {
				return try await operation()
			} catch {
				guard attempt < webAttemptLimit else {
					throw error
				}
				attempt += 1
				switch CloudKitZoneResult.resolve(error) {
				case .retry(let seconds):
					// A longer wait fails at once: the service turns every request away until then
					// (`CloudKitWebService.throttledUntil`), and a later sync tries again.
					guard seconds <= webMaxRetryDelay else {
						throw error
					}
					Self.webLogger.debug("CloudKitZone: \(self.zoneID.zoneName, privacy: .public) web request retry in \(seconds) seconds")
					await delaySeconds(seconds)
				case .zoneNotFound where createsMissingZone:
					Self.webLogger.info("CloudKitZone: \(self.zoneID.zoneName, privacy: .public) zone not found; creating it")
					try await webDatabase.saveZone(zoneID)
				default:
					guard let ckError = error as? CKError, ckError.code == .networkFailure || ckError.code == .networkUnavailable else {
						throw error
					}
					Self.webLogger.debug("CloudKitZone: \(self.zoneID.zoneName, privacy: .public) web request network failure; retrying")
					await delaySeconds(webNetworkRetryDelay)
				}
			}
		}
	}
}
