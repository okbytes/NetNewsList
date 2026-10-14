//
//  CloudKitWebRecordCoder.swift
//  CloudKitSync
//
//  Turns CloudKit Web Services’ record dictionaries into CKRecords and back, so the sync
//  code works with CKRecords whichever way it reaches iCloud.
//

import Foundation
import CloudKit

/// A record as CloudKit Web Services sent it, turned into a CKRecord. Asset fields come
/// separately: they’re downloaded before the record is handed on.
struct CloudKitWebReceivedRecord: @unchecked Sendable {
	let record: CKRecord
	let recordChangeTag: String?
	/// Asset fields: field name to the address its file downloads from.
	let assetDownloadURLs: [String: URL]
}

/// One failure a records request reported for one record.
struct CloudKitWebRecordFailure: Sendable {
	let recordName: String
	let serverErrorCode: String
	let reason: String?
	let retryAfter: TimeInterval?
}

enum CloudKitWebRecordCoder {

	// MARK: - Receiving

	/// A record dictionary from lookup, query or changes, or nil when it describes a failure or a deletion.
	static func receivedRecord(from dictionary: [String: Any], zoneID: CKRecordZone.ID) -> CloudKitWebReceivedRecord? {
		guard dictionary["serverErrorCode"] == nil,
			  (dictionary["deleted"] as? Bool) != true,
			  let recordName = dictionary["recordName"] as? String,
			  let recordType = dictionary["recordType"] as? String else {
			return nil
		}
		let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
		var assetDownloadURLs = [String: URL]()
		for (fieldName, fieldValue) in dictionary["fields"] as? [String: Any] ?? [:] {
			guard let field = fieldValue as? [String: Any] else {
				continue
			}
			if let downloadURL = assetDownloadURL(field) {
				assetDownloadURLs[fieldName] = downloadURL
				continue
			}
			if let value = recordValue(field, zoneID: zoneID) {
				record[fieldName] = value
			}
		}
		return CloudKitWebReceivedRecord(record: record, recordChangeTag: dictionary["recordChangeTag"] as? String, assetDownloadURLs: assetDownloadURLs)
	}

	static func failure(from dictionary: [String: Any]) -> CloudKitWebRecordFailure? {
		guard let serverErrorCode = dictionary["serverErrorCode"] as? String else {
			return nil
		}
		return CloudKitWebRecordFailure(recordName: dictionary["recordName"] as? String ?? "",
										serverErrorCode: serverErrorCode,
										reason: dictionary["reason"] as? String,
										retryAfter: (dictionary["retryAfter"] as? NSNumber)?.doubleValue)
	}

	/// A field’s value as a CKRecord value. Nil for a type the apps don’t use.
	static func recordValue(_ field: [String: Any], zoneID: CKRecordZone.ID) -> CKRecordValue? {
		let type = field["type"] as? String
		let value = field["value"]
		switch type {
		case "STRING":
			return value as? String as NSString?
		case "INT64":
			return (value as? NSNumber).map { NSNumber(value: $0.int64Value) }
		case "DOUBLE":
			return (value as? NSNumber).map { NSNumber(value: $0.doubleValue) }
		case "TIMESTAMP":
			return (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) as NSDate }
		case "BYTES":
			return (value as? String).flatMap { Data(base64Encoded: $0) } as NSData?
		case "REFERENCE":
			return (value as? [String: Any]).flatMap { reference($0, zoneID: zoneID) }
		case "STRING_LIST":
			return (value as? [Any])?.compactMap { $0 as? String } as NSArray?
		case "INT64_LIST", "DOUBLE_LIST":
			return (value as? [Any])?.compactMap { $0 as? NSNumber } as NSArray?
		case "TIMESTAMP_LIST":
			return (value as? [Any])?.compactMap { ($0 as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } } as NSArray?
		case "BYTES_LIST":
			return (value as? [Any])?.compactMap { ($0 as? String).flatMap { Data(base64Encoded: $0) } } as NSArray?
		case "REFERENCE_LIST":
			return (value as? [Any])?.compactMap { ($0 as? [String: Any]).flatMap { reference($0, zoneID: zoneID) } } as NSArray?
		case "LIST", "UNKNOWN_LIST":
			// A list without its element type (iCloud reports an empty list as UNKNOWN_LIST).
			// The apps’ lists are lists of strings.
			return (value as? [Any])?.compactMap { $0 as? String } as NSArray?
		default:
			// No type: infer the simple ones, as CloudKit does for a write without one.
			if let string = value as? String {
				return string as NSString
			}
			if let strings = value as? [String] {
				return strings as NSArray
			}
			return nil
		}
	}

	static func reference(_ dictionary: [String: Any], zoneID: CKRecordZone.ID) -> CKRecord.Reference? {
		guard let recordName = dictionary["recordName"] as? String else {
			return nil
		}
		let action: CKRecord.ReferenceAction = (dictionary["action"] as? String) == "DELETE_SELF" ? .deleteSelf : .none
		return CKRecord.Reference(recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID), action: action)
	}

	/// The download address of an ASSETID field. CloudKit leaves a `${f}` in it for a file name.
	static func assetDownloadURL(_ field: [String: Any]) -> URL? {
		guard field["type"] as? String == "ASSETID",
			  let asset = field["value"] as? [String: Any],
			  let address = asset["downloadURL"] as? String else {
			return nil
		}
		return URL(string: address.replacingOccurrences(of: "${f}", with: "asset"))
	}

	// MARK: - Sending

	/// The JSON for one of a record’s fields, as `records/modify` takes it. Nil for a value
	/// the apps don’t use (and so never send).
	static func field(_ value: CKRecordValue?) -> [String: Any]? {
		switch value {
		case nil:
			return nil
		case let string as String:
			return ["value": string, "type": "STRING"]
		case let date as Date:
			return ["value": timestamp(date), "type": "TIMESTAMP"]
		case let data as Data:
			return ["value": data.base64EncodedString(), "type": "BYTES"]
		case let reference as CKRecord.Reference:
			return ["value": referenceValue(reference), "type": "REFERENCE"]
		case let number as NSNumber:
			if CFNumberIsFloatType(number) {
				return ["value": number.doubleValue, "type": "DOUBLE"]
			}
			return ["value": number.int64Value, "type": "INT64"]
		case let array as [Any]:
			return listField(array)
		default:
			return nil
		}
	}

	static func listField(_ array: [Any]) -> [String: Any]? {
		if let strings = array as? [String] {
			return ["value": strings, "type": "STRING_LIST"]
		}
		if let dates = array as? [Date] {
			return ["value": dates.map { timestamp($0) }, "type": "TIMESTAMP_LIST"]
		}
		if let references = array as? [CKRecord.Reference] {
			return ["value": references.map { referenceValue($0) }, "type": "REFERENCE_LIST"]
		}
		if let datas = array as? [Data] {
			return ["value": datas.map { $0.base64EncodedString() }, "type": "BYTES_LIST"]
		}
		if let numbers = array as? [NSNumber] {
			if numbers.contains(where: { CFNumberIsFloatType($0) }) {
				return ["value": numbers.map(\.doubleValue), "type": "DOUBLE_LIST"]
			}
			return ["value": numbers.map(\.int64Value), "type": "INT64_LIST"]
		}
		return nil
	}

	/// Milliseconds since 1970, which is what a TIMESTAMP holds.
	static func timestamp(_ date: Date) -> Int64 {
		Int64((date.timeIntervalSince1970 * 1000).rounded())
	}

	static func referenceValue(_ reference: CKRecord.Reference) -> [String: Any] {
		var value: [String: Any] = [
			"recordName": reference.recordID.recordName,
			"action": reference.action == .deleteSelf ? "DELETE_SELF" : "NONE"
		]
		if reference.recordID.zoneID.zoneName != CKRecordZone.ID.defaultZoneName {
			value["zoneID"] = ["zoneName": reference.recordID.zoneID.zoneName]
		}
		return value
	}
}
