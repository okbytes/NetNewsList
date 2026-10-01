//
//  ShareViewController.swift
//  NetNewsList Share Extension
//
//  Saves the shared page in one step: it leaves a request in the app-group inbox,
//  shows a short confirmation and closes. The app saves and extracts the page.
//

import AppKit
import os
import RSCore

final class ShareViewController: NSViewController {

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ShareViewController")
	private let messageField = NSTextField(labelWithString: NSLocalizedString("Saving to NetNewsList…", comment: "Share extension: saving"))

	override func loadView() {
		messageField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
		messageField.alignment = .center
		messageField.lineBreakMode = .byTruncatingMiddle
		messageField.translatesAutoresizingMaskIntoConstraints = false

		let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
		view.addSubview(messageField)
		NSLayoutConstraint.activate([
			messageField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			messageField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			messageField.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
			messageField.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
		])
		self.view = view
	}

	override func viewDidAppear() {
		super.viewDidAppear()
		let inputItems = extensionContext?.inputItems ?? []
		Task { @MainActor in
			await save(inputItems)
		}
	}
}

private extension ShareViewController {

	func save(_ inputItems: [Any]) async {
		guard let page = await SharedPageResolver.resolve(inputItems) else {
			finish(NSLocalizedString("There’s no web page to save.", comment: "Share extension: nothing to save"), succeeded: false)
			return
		}
		do {
			try SavedArticleInbox.add(SavedArticleRequest(url: page.url.absoluteString, title: page.title, body: page.body))
			finish(NSLocalizedString("Saved to NetNewsList", comment: "Share extension: saved"), succeeded: true)
		} catch {
			Self.logger.error("ShareViewController: couldn’t save \(page.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
			finish(NSLocalizedString("Couldn’t save the page. Open NetNewsList and use Add Article.", comment: "Share extension: failed"), succeeded: false)
		}
	}

	func finish(_ message: String, succeeded: Bool) {
		messageField.stringValue = message
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(succeeded ? 700 : 2000))
			self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
		}
	}
}
