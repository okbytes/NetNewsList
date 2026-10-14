//
//  CloudKitWebDatabase.swift
//  CloudKitSync
//
//  The private database operations CloudKitZone uses, over CloudKit Web Services, in the
//  CloudKit framework’s terms: CKRecords in and out, and CKErrors with the codes the
//  framework would report, so the zones and their delegates run the same code either way.
//

import Foundation
import CloudKit
import os
import RSCore

public final class CloudKitWebDatabase: Sendable {

	nonisolated private static let logger = cloudKitLogger

	/// How a save treats the copy iCloud has, as CKModifyRecordsOperation’s save policies do.
	enum SavePolicy: Sendable {
		/// Writes the changed fields over iCloud’s copy, creating the record if it’s missing.
		case changedKeys
		/// Creates a new record only if iCloud has none; saves a fetched one only if iCloud’s
		/// copy hasn’t changed since.
		case ifServerRecordUnchanged
	}

	/// Most operations one `records/modify` request carries, and roughly how big it may get.
	/// iCloud documents the first; the second is kept modest because it isn’t documented.
	static let maxOperationsPerRequest = 200
	static let maxRequestBytes = 2_000_000

	private let serviceProvider: @MainActor @Sendable () -> CloudKitWebService?
	private let changeTags = CloudKitWebChangeTags()
	private let assetFolder: URL

	/// `serviceProvider` gives the current client: nil until an API token is configured.
	public init(serviceProvider: @escaping @MainActor @Sendable () -> CloudKitWebService?) {
		self.serviceProvider = serviceProvider
		assetFolder = FileManager.default.temporaryDirectory.appendingPathComponent("CloudKitWebAssets", isDirectory: true)
		try? FileManager.default.removeItem(at: assetFolder)
	}

	// MARK: - Zones

	@concurrent func saveZone(_ zoneID: CKRecordZone.ID) async throws {
		let body: [String: Any] = ["operations": [["operationType": "create", "zone": ["zoneID": Self.zoneIDValue(zoneID)]]]]
		let json = try await post("zones/modify", body)
		if let zone = (json["zones"] as? [[String: Any]])?.first, let failure = CloudKitWebRecordCoder.failure(from: zone) {
			// A zone that already exists is what this asked for.
			if failure.serverErrorCode == "EXISTS" || failure.serverErrorCode == "CONFLICT" {
				return
			}
			throw Self.ckError(for: failure)
		}
	}

	// MARK: - Records

	/// Fetches records by ID. A missing record’s result is a CKError `unknownItem`.
	@concurrent func records(for recordIDs: [CKRecord.ID], desiredKeys: [String]? = nil) async throws -> [CKRecord.ID: Result<CKRecord, CKError>] {
		var results = [CKRecord.ID: Result<CKRecord, CKError>]()
		for (zoneID, zoneRecordIDs) in Dictionary(grouping: recordIDs, by: \.zoneID) {
			for chunk in zoneRecordIDs.chunked(into: Self.maxOperationsPerRequest) {
				var body: [String: Any] = [
					"records": chunk.map { ["recordName": $0.recordName] },
					"zoneID": Self.zoneIDValue(zoneID)
				]
				if let desiredKeys {
					body["desiredKeys"] = desiredKeys
				}
				let json = try await post("records/lookup", body)
				let recordIDsByName = Dictionary(chunk.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
				for dictionary in json["records"] as? [[String: Any]] ?? [] {
					if let failure = CloudKitWebRecordCoder.failure(from: dictionary) {
						if let recordID = recordIDsByName[failure.recordName] {
							results[recordID] = .failure(Self.ckError(for: failure))
						}
						continue
					}
					guard let received = CloudKitWebRecordCoder.receivedRecord(from: dictionary, zoneID: zoneID),
						  let recordID = recordIDsByName[received.record.recordID.recordName] else {
						continue
					}
					results[recordID] = .success(try await finish(received))
				}
			}
		}
		return results
	}

	/// One page of a query. `continuationMarker` continues a previous page.
	@concurrent func query(_ query: CKQuery, zoneID: CKRecordZone.ID, desiredKeys: [String]?, continuationMarker: String?) async throws -> (records: [CKRecord], continuationMarker: String?) {
		var body: [String: Any] = [
			"zoneID": Self.zoneIDValue(zoneID),
			"query": ["recordType": query.recordType, "filterBy": try Self.filters(for: query.predicate)]
		]
		if let desiredKeys {
			body["desiredKeys"] = desiredKeys
		}
		if let continuationMarker {
			body["continuationMarker"] = continuationMarker
		}
		let json = try await post("records/query", body)
		var records = [CKRecord]()
		for dictionary in json["records"] as? [[String: Any]] ?? [] {
			if let received = CloudKitWebRecordCoder.receivedRecord(from: dictionary, zoneID: zoneID) {
				records.append(try await finish(received))
			}
		}
		return (records, json["continuationMarker"] as? String)
	}

	/// One page of the changes in a zone since `syncToken` (everything, when it’s nil). A
	/// deletion’s record type is usually missing: iCloud reports only the record’s name.
	@concurrent func changes(in zoneID: CKRecordZone.ID, syncToken: String?) async throws -> (changed: [CKRecord], deleted: [CloudKitRecordKey], syncToken: String?, moreComing: Bool) {
		var zone: [String: Any] = ["zoneID": Self.zoneIDValue(zoneID)]
		// An empty token reads as “caught up”, so only a real one is sent.
		if let syncToken, !syncToken.isEmpty {
			zone["syncToken"] = syncToken
		}
		let json = try await post("changes/zone", ["zones": [zone]])
		guard let zoneResult = (json["zones"] as? [[String: Any]])?.first else {
			throw CloudKitWebServiceError.invalidResponse(status: 200)
		}
		if let failure = CloudKitWebRecordCoder.failure(from: zoneResult) {
			// iCloud documents no expired-token error; a token it no longer takes comes back as
			// BAD_REQUEST. Fetching everything again is what the CloudKit framework path does.
			if failure.serverErrorCode == "BAD_REQUEST" && zone["syncToken"] != nil {
				throw CKError(.changeTokenExpired, userInfo: [NSLocalizedDescriptionKey: failure.reason ?? failure.serverErrorCode])
			}
			throw Self.ckError(for: failure)
		}
		var changed = [CKRecord]()
		var deleted = [CloudKitRecordKey]()
		for dictionary in zoneResult["records"] as? [[String: Any]] ?? [] {
			if let failure = CloudKitWebRecordCoder.failure(from: dictionary) {
				throw Self.ckError(for: failure)
			}
			guard let recordName = dictionary["recordName"] as? String else {
				continue
			}
			if (dictionary["deleted"] as? Bool) == true {
				let recordType = dictionary["recordType"] as? String ?? ""
				deleted.append(CloudKitRecordKey(recordType: recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID)))
				continue
			}
			if let received = CloudKitWebRecordCoder.receivedRecord(from: dictionary, zoneID: zoneID) {
				changed.append(try await finish(received))
			}
		}
		let newSyncToken = (zoneResult["syncToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
		return (changed, deleted, newSyncToken, (zoneResult["moreComing"] as? Bool) ?? false)
	}

	/// Saves and deletes records in one zone. Returns the records iCloud didn’t save or delete,
	/// with their errors; with `atomic`, any failure means nothing was saved. Request-level
	/// failures are thrown.
	@concurrent func modify(save recordsToSave: [CKRecord], delete recordIDsToDelete: [CKRecord.ID], policy: SavePolicy, atomic: Bool) async throws -> [CKRecord.ID: CKError] {
		guard !(recordsToSave.isEmpty && recordIDsToDelete.isEmpty) else {
			return [:]
		}
		let zoneID = recordsToSave.first?.recordID.zoneID ?? recordIDsToDelete[0].zoneID

		var operations = [CloudKitWebOperation]()
		for record in recordsToSave {
			operations.append(try await operation(saving: record, policy: policy))
		}
		for recordID in recordIDsToDelete {
			operations.append(CloudKitWebOperation(recordID: recordID, operationType: "forceDelete", record: ["recordName": recordID.recordName], savedRecord: nil))
		}

		var failures = [CKRecord.ID: CKError]()
		for batch in Self.batches(operations, atomic: atomic) {
			failures.merge(try await send(batch, zoneID: zoneID, policy: policy, atomic: atomic)) { first, _ in first }
		}
		return failures
	}
}

// MARK: - Operations

private struct CloudKitWebOperation: @unchecked Sendable {
	let recordID: CKRecord.ID
	var operationType: String
	var record: [String: Any]
	/// The record being saved, so iCloud’s new change tag can be remembered for it.
	let savedRecord: CKRecord?

	var json: [String: Any] {
		["operationType": operationType, "record": record]
	}

	/// Fields set to nil, sent as `{"value": null}` to clear them in iCloud.
	var hasClearedFields: Bool {
		(record["fields"] as? [String: Any] ?? [:]).values.contains { field in
			((field as? [String: Any])?["value"]) is NSNull
		}
	}

	var jsonWithoutClearedFields: [String: Any] {
		var record = record
		if let fields = record["fields"] as? [String: Any] {
			record["fields"] = fields.filter { _, field in !(((field as? [String: Any])?["value"]) is NSNull) }
		}
		return ["operationType": operationType, "record": record]
	}

	var estimatedBytes: Int {
		(try? JSONSerialization.data(withJSONObject: json).count) ?? 0
	}
}

private extension CloudKitWebDatabase {

	/// The operation that saves a record’s changed fields under a save policy, with its assets uploaded.
	func operation(saving record: CKRecord, policy: SavePolicy) async throws -> CloudKitWebOperation {
		var fields = [String: Any]()
		for key in record.changedKeys() {
			let value = record[key]
			if let asset = value as? CKAsset {
				fields[key] = try await uploadedAssetField(asset, record: record, fieldName: key)
			} else if let field = CloudKitWebRecordCoder.field(value) {
				fields[key] = field
			} else if value == nil {
				fields[key] = Self.clearedField
			}
		}

		var dictionary: [String: Any] = [
			"recordName": record.recordID.recordName,
			"recordType": record.recordType,
			"fields": fields
		]
		let operationType: String
		switch policy {
		case .changedKeys:
			operationType = "forceUpdate"
		case .ifServerRecordUnchanged:
			if let tag = changeTags.tag(for: record) {
				dictionary["recordChangeTag"] = tag
				operationType = "update"
			} else {
				operationType = "create"
			}
		}
		return CloudKitWebOperation(recordID: record.recordID, operationType: operationType, record: dictionary, savedRecord: record)
	}

	/// Splits operations into requests iCloud accepts. An atomic save that doesn’t fit in one
	/// request is sent in parts, as the CloudKit framework does when a request is too big.
	static func batches(_ operations: [CloudKitWebOperation], atomic: Bool) -> [[CloudKitWebOperation]] {
		var batches = [[CloudKitWebOperation]]()
		var current = [CloudKitWebOperation]()
		var currentBytes = 0
		for operation in operations {
			let bytes = operation.estimatedBytes
			if !current.isEmpty && (current.count >= maxOperationsPerRequest || currentBytes + bytes > maxRequestBytes) {
				batches.append(current)
				current = []
				currentBytes = 0
			}
			current.append(operation)
			currentBytes += bytes
		}
		if !current.isEmpty {
			batches.append(current)
		}
		return batches
	}

	/// Sends one batch, and sends it again when iCloud’s answer calls for it:
	/// - A `forceUpdate` should create a missing record; one that fails as NOT_FOUND goes
	///   again as a create, which is what the CloudKit framework’s changed-keys save does.
	/// - An atomic request refused as a whole, without naming the record that caused it,
	///   goes again record by record, so the others are saved and the culprit gets its error.
	/// - Clearing a field (`{"value": null}`) isn’t documented for CloudKit Web Services. If
	///   iCloud refuses it, the save goes again without clearing: a stale value is left in a
	///   field the app has emptied, rather than nothing saved.
	/// Each fallback is taken at most once.
	func send(_ batch: [CloudKitWebOperation], zoneID: CKRecordZone.ID, policy: SavePolicy, atomic: Bool) async throws -> [CKRecord.ID: CKError] {
		var operations = batch
		var atomic = atomic
		var sendsClearedFields = true
		var didCreateMissingRecords = false
		while true {
			let body: [String: Any] = [
				"operations": operations.map { sendsClearedFields ? $0.json : $0.jsonWithoutClearedFields },
				"zoneID": Self.zoneIDValue(zoneID),
				"atomic": atomic,
				// Don’t echo the saved fields back: an article body would come back as large as it went.
				"desiredKeys": [String]()
			]
			let json: [String: Any]
			do {
				json = try await post("records/modify", body)
			} catch let error as CKError where error.code == .batchRequestFailed && atomic {
				Self.logger.info("CloudKitWebDatabase: an atomic save failed as a whole; sending it again record by record")
				atomic = false
				continue
			} catch let error as CKError where error.code == .invalidArguments && sendsClearedFields && operations.contains(where: \.hasClearedFields) {
				Self.logger.error("CloudKitWebDatabase: iCloud refused to clear fields; saving without clearing them")
				sendsClearedFields = false
				continue
			}

			let operationsByName = Dictionary(operations.map { ($0.recordID.recordName, $0) }, uniquingKeysWith: { first, _ in first })
			var failures = [CKRecord.ID: CloudKitWebRecordFailure]()
			for dictionary in json["records"] as? [[String: Any]] ?? [] {
				if let failure = CloudKitWebRecordCoder.failure(from: dictionary) {
					if let operation = operationsByName[failure.recordName] {
						failures[operation.recordID] = failure
					}
					continue
				}
				if let recordName = dictionary["recordName"] as? String,
				   let savedRecord = operationsByName[recordName]?.savedRecord,
				   let tag = dictionary["recordChangeTag"] as? String {
					changeTags.setTag(tag, for: savedRecord)
				}
			}

			// Deleting a record iCloud no longer has leaves it gone, which is what was asked.
			failures = failures.filter { recordID, failure in
				!(failure.serverErrorCode == "NOT_FOUND" && operationsByName[recordID.recordName]?.operationType == "forceDelete")
			}
			guard !failures.isEmpty else {
				return [:]
			}

			let missingRecordNames = Set(failures.filter { recordID, failure in
				failure.serverErrorCode == "NOT_FOUND" && operationsByName[recordID.recordName]?.operationType == "forceUpdate"
			}.keys.map(\.recordName))
			let refusedClears = sendsClearedFields && failures.contains { recordID, failure in
				failure.serverErrorCode == "BAD_REQUEST" && operationsByName[recordID.recordName]?.hasClearedFields == true
			}

			if policy == .changedKeys && !didCreateMissingRecords && !missingRecordNames.isEmpty {
				Self.logger.debug("CloudKitWebDatabase: creating \(missingRecordNames.count) records iCloud doesn’t have yet")
				didCreateMissingRecords = true
			} else if refusedClears {
				Self.logger.error("CloudKitWebDatabase: iCloud refused to clear fields; saving without clearing them")
				sendsClearedFields = false
			} else {
				return try await ckErrors(for: failures, operations: operationsByName, zoneID: zoneID)
			}

			// Atomic: nothing was saved, so everything goes again. Otherwise only what failed.
			operations = operations.compactMap { operation in
				var operation = operation
				if missingRecordNames.contains(operation.recordID.recordName) {
					operation.operationType = "create"
				}
				return atomic || failures[operation.recordID] != nil ? operation : nil
			}
		}
	}

	/// CKErrors for per-record failures. A save that found iCloud’s copy changed gets that copy
	/// as its `serverRecord`, as the CloudKit framework’s `serverRecordChanged` error does.
	func ckErrors(for failures: [CKRecord.ID: CloudKitWebRecordFailure], operations: [String: CloudKitWebOperation], zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID: CKError] {
		guard !failures.isEmpty else {
			return [:]
		}
		let conflictedIDs = failures.filter { Self.isConflict($0.value) }.map(\.key)
		var serverRecords = [CKRecord.ID: CKRecord]()
		if !conflictedIDs.isEmpty {
			let fetched = (try? await records(for: conflictedIDs)) ?? [:]
			for (recordID, result) in fetched {
				if case .success(let record) = result {
					serverRecords[recordID] = record
				}
			}
		}
		var errors = [CKRecord.ID: CKError]()
		for (recordID, failure) in failures {
			if Self.isConflict(failure) {
				var userInfo = [String: Any]()
				userInfo[NSLocalizedDescriptionKey] = failure.reason
				userInfo[CKRecordChangedErrorServerRecordKey] = serverRecords[recordID]
				errors[recordID] = CKError(.serverRecordChanged, userInfo: userInfo)
			} else {
				errors[recordID] = Self.ckError(for: failure)
			}
		}
		return errors
	}

	/// Uploads an asset’s file and returns the field that refers to it.
	func uploadedAssetField(_ asset: CKAsset, record: CKRecord, fieldName: String) async throws -> [String: Any] {
		guard let fileURL = asset.fileURL else {
			throw CKError(.assetFileNotFound)
		}
		let data = try Data(contentsOf: fileURL)
		let body: [String: Any] = [
			"zoneID": Self.zoneIDValue(record.recordID.zoneID),
			"tokens": [["recordType": record.recordType, "recordName": record.recordID.recordName, "fieldName": fieldName]]
		]
		let json = try await post("assets/upload", body)
		guard let token = (json["tokens"] as? [[String: Any]])?.first,
			  let address = token["url"] as? String,
			  let uploadURL = URL(string: address) else {
			throw CKError(.internalError, userInfo: [NSLocalizedDescriptionKey: "iCloud didn’t give an address to upload the asset to"])
		}
		let service = try await currentService()
		let response: Data
		do {
			response = try await service.uploadAssetData(data, to: uploadURL)
		} catch {
			throw Self.ckError(for: error)
		}
		guard let responseJSON = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
			  let singleFile = responseJSON["singleFile"] as? [String: Any] else {
			throw CKError(.internalError, userInfo: [NSLocalizedDescriptionKey: "iCloud’s answer to an asset upload had no file"])
		}
		// Apple’s example writes the uploaded file without a type; the schema has it.
		return ["value": singleFile]
	}

	/// Downloads a received record’s assets into files and remembers its change tag.
	func finish(_ received: CloudKitWebReceivedRecord) async throws -> CKRecord {
		let record = received.record
		if let tag = received.recordChangeTag {
			changeTags.setTag(tag, for: record)
		}
		guard !received.assetDownloadURLs.isEmpty else {
			return record
		}
		let service = try await currentService()
		for (fieldName, downloadURL) in received.assetDownloadURLs {
			let data: Data
			do {
				data = try await service.downloadAsset(from: downloadURL)
			} catch {
				throw Self.ckError(for: error)
			}
			try FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
			let fileURL = assetFolder.appendingPathComponent(UUID().uuidString)
			try data.write(to: fileURL)
			record[fieldName] = CKAsset(fileURL: fileURL)
		}
		return record
	}

	func currentService() async throws -> CloudKitWebService {
		guard let service = await serviceProvider() else {
			throw CloudKitWebServiceError.notConfigured
		}
		return service
	}

	/// Sends a request and returns its JSON, with request-level failures as CKErrors where the
	/// CloudKit framework has a matching one (so retries and zone creation work as usual).
	func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
		let service = try await currentService()
		let bodyData = try JSONSerialization.data(withJSONObject: body)
		let responseData: Data
		do {
			responseData = try await service.send(path: path, body: bodyData)
		} catch {
			throw Self.ckError(for: error)
		}
		guard let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
			throw CloudKitWebServiceError.invalidResponse(status: 200)
		}
		return json
	}

	static func zoneIDValue(_ zoneID: CKRecordZone.ID) -> [String: Any] {
		["zoneName": zoneID.zoneName]
	}

	/// The `filterBy` of a query: the comparisons the apps make, `field = value` and
	/// `listField CONTAINS value`, joined by AND.
	static func filters(for predicate: NSPredicate) throws -> [[String: Any]] {
		if let compound = predicate as? NSCompoundPredicate, compound.compoundPredicateType == .and {
			return try compound.subpredicates.flatMap { subpredicate -> [[String: Any]] in
				guard let subpredicate = subpredicate as? NSPredicate else {
					throw CKError(.invalidArguments)
				}
				return try filters(for: subpredicate)
			}
		}
		if predicate == NSPredicate(value: true) {
			return []
		}
		guard let comparison = predicate as? NSComparisonPredicate,
			  comparison.leftExpression.expressionType == .keyPath,
			  comparison.rightExpression.expressionType == .constantValue,
			  let field = CloudKitWebRecordCoder.field(comparison.rightExpression.constantValue as? CKRecordValue) else {
			throw CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "A query iCloud on the web can’t run: \(predicate)"])
		}
		let fieldName = comparison.leftExpression.keyPath
		switch comparison.predicateOperatorType {
		case .equalTo:
			return [["comparator": "EQUALS", "fieldName": fieldName, "fieldValue": field]]
		case .contains:
			return [["comparator": "LIST_CONTAINS", "fieldName": fieldName, "fieldValue": field]]
		default:
			throw CKError(.invalidArguments, userInfo: [NSLocalizedDescriptionKey: "A query iCloud on the web can’t run: \(predicate)"])
		}
	}

	static func isConflict(_ failure: CloudKitWebRecordFailure) -> Bool {
		failure.serverErrorCode == "CONFLICT" || failure.serverErrorCode == "EXISTS"
	}

	/// What a field holds to clear its value in iCloud.
	static var clearedField: [String: Any] {
		["value": NSNull()]
	}
}

// MARK: - Errors

extension CloudKitWebDatabase {

	/// The CKError for a failure iCloud reported for one record or one zone.
	static func ckError(for failure: CloudKitWebRecordFailure) -> CKError {
		ckError(code: failure.serverErrorCode, reason: failure.reason, status: nil, retryAfter: failure.retryAfter)
	}

	/// A request’s error as the CloudKit framework would report it. Sign-in and configuration
	/// errors stay as they are: their messages say what to do.
	static func ckError(for error: Error) -> Error {
		switch error {
		case CloudKitWebServiceError.server(let code, let reason, let status, let retryAfter):
			return ckError(code: code, reason: reason, status: status, retryAfter: retryAfter)
		case let urlError as URLError:
			let code: CKError.Code = urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost ? .networkUnavailable : .networkFailure
			return CKError(code, userInfo: [NSUnderlyingErrorKey: urlError, NSLocalizedDescriptionKey: urlError.localizedDescription])
		default:
			return error
		}
	}

	static func ckError(code: String, reason: String?, status: Int?, retryAfter: TimeInterval?) -> CKError {
		var userInfo = [String: Any]()
		if let reason {
			userInfo[NSLocalizedDescriptionKey] = "\(reason) (\(code))"
		}
		func retrying(_ ckCode: CKError.Code, after seconds: TimeInterval) -> CKError {
			userInfo[CKErrorRetryAfterKey] = NSNumber(value: retryAfter ?? seconds)
			return CKError(ckCode, userInfo: userInfo)
		}
		switch code {
		case "ZONE_NOT_FOUND":
			return CKError(.zoneNotFound, userInfo: userInfo)
		case "NOT_FOUND", "UNKNOWN_ITEM":
			return CKError(.unknownItem, userInfo: userInfo)
		case "CONFLICT", "EXISTS":
			return CKError(.serverRecordChanged, userInfo: userInfo)
		case "QUOTA_EXCEEDED":
			return CKError(.quotaExceeded, userInfo: userInfo)
		case "LIMIT_EXCEEDED":
			return CKError(.limitExceeded, userInfo: userInfo)
		case "ATOMIC_ERROR":
			return CKError(.batchRequestFailed, userInfo: userInfo)
		case "VALIDATING_REFERENCE_ERROR":
			return CKError(.referenceViolation, userInfo: userInfo)
		case "ACCESS_DENIED":
			return CKError(.permissionFailure, userInfo: userInfo)
		case "ZONE_BUSY":
			return retrying(.zoneBusy, after: 10)
		case "THROTTLED":
			return retrying(.requestRateLimited, after: 10)
		case "TRY_AGAIN_LATER":
			return retrying(.serviceUnavailable, after: 10)
		case "SYNC_TOKEN_EXPIRED", "CHANGE_TOKEN_EXPIRED":
			return CKError(.changeTokenExpired, userInfo: userInfo)
		case "BAD_REQUEST":
			if let reason, reason.localizedCaseInsensitiveContains("sync token") || reason.localizedCaseInsensitiveContains("synctoken") {
				return CKError(.changeTokenExpired, userInfo: userInfo)
			}
			return CKError(.invalidArguments, userInfo: userInfo)
		default:
			switch status {
			case 413:
				return CKError(.limitExceeded, userInfo: userInfo)
			case 421:
				// Not iCloud asking for a sign-in (that comes with AUTHENTICATION_REQUIRED):
				// HTTP/2’s Misdirected Request, which a new connection fixes.
				return CKError(.networkFailure, userInfo: userInfo)
			case 429:
				return retrying(.requestRateLimited, after: 10)
			case 500, 502, 503, 504:
				return retrying(.serviceUnavailable, after: 10)
			default:
				return CKError(.serverRejectedRequest, userInfo: userInfo)
			}
		}
	}
}

/// The change tag iCloud last reported for each CKRecord object this database handed out
/// or saved. A CKRecord made here can’t carry its tag (it’s read-only), and a save that
/// must not overwrite a newer copy needs it.
private final class CloudKitWebChangeTags: @unchecked Sendable {

	private let lock = NSLock()
	private let tags = NSMapTable<CKRecord, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

	func tag(for record: CKRecord) -> String? {
		lock.lock()
		defer {
			lock.unlock()
		}
		return tags.object(forKey: record) as String?
	}

	func setTag(_ tag: String, for record: CKRecord) {
		lock.lock()
		defer {
			lock.unlock()
		}
		tags.setObject(tag as NSString, forKey: record)
	}
}
