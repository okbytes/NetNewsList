//
//  ReadingListBackups.swift
//  NetNewsList
//
//  Keeps dated JSON snapshots of the whole reading list on this Mac, outside iCloud
//  sync, which would mirror a mistaken delete everywhere: one a day when the list has
//  changed, the newest 30. File > Show Backups in Finder.
//

import AppKit
import os
import RSCore
import Account

@MainActor final class ReadingListBackups {

	static let shared = ReadingListBackups()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "Backups")
	private static let interval: TimeInterval = 24 * 60 * 60
	private static let maximumCount = 30
	private static let fileNamePrefix = "NetNewsList "

	/// `Application Support/NetNewsList/Backups` in the app’s container.
	let folderURL: URL
	private var timer: Timer?
	private var lastBackUpDate: Date?

	private init() {
		let applicationSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
		folderURL = applicationSupport.appendingPathComponent("NetNewsList", isDirectory: true).appendingPathComponent("Backups", isDirectory: true)
	}

	/// Backs up now, then whenever a day has passed. The hourly check uses the clock,
	/// so time the Mac spends asleep counts.
	func start() {
		guard timer == nil else {
			return
		}
		backUpIfDue()
		timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
			Task { @MainActor in
				ReadingListBackups.shared.backUpIfDue()
			}
		}
	}

	func showInFinder() {
		try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
		if let newest = backupFileURLs().last {
			NSWorkspace.shared.activateFileViewerSelecting([newest])
		} else {
			NSWorkspace.shared.open(folderURL)
		}
	}
}

private extension ReadingListBackups {

	func backUpIfDue() {
		if let lastBackUpDate, Date().timeIntervalSince(lastBackUpDate) < Self.interval {
			return
		}
		lastBackUpDate = Date()
		Task {
			await backUp()
		}
	}

	/// Writes a snapshot unless the newest one has the same contents, then keeps the newest 30.
	func backUp() async {
		do {
			let data = try await AccountManager.shared.defaultAccount.readingListBackupData()
			try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
			if let newest = backupFileURLs().last, (try? Data(contentsOf: newest)) == data {
				return
			}
			let fileURL = folderURL.appendingPathComponent(Self.fileNamePrefix + Self.fileNameDateFormatter.string(from: Date())).appendingPathExtension("json")
			try data.write(to: fileURL, options: .atomic)
			Self.logger.info("Backups: wrote \(fileURL.lastPathComponent, privacy: .public)")
			for oldURL in backupFileURLs().dropLast(Self.maximumCount) {
				try? FileManager.default.removeItem(at: oldURL)
			}
		} catch {
			Self.logger.error("Backups: couldn’t write a backup: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Oldest first: the names sort by date.
	func backupFileURLs() -> [URL] {
		let fileURLs = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
		return fileURLs.filter { $0.lastPathComponent.hasPrefix(Self.fileNamePrefix) && $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	static let fileNameDateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
		return formatter
	}()
}
