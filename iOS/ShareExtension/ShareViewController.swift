//
//  ShareViewController.swift
//  NetNewsList iOS Share Extension
//
//  Saves the shared page in one step: it leaves a request in the app-group inbox,
//  shows a short confirmation and closes. The app saves and extracts the page the
//  next time it runs.
//

import UIKit
import os
import UniformTypeIdentifiers
import RSCore

// The share extension’s principal class (see NSExtensionPrincipalClass in Info.plist).
@objc(ShareViewController)
final class ShareViewController: UIViewController {

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ShareViewController")
	private let imageView = UIImageView(image: UIImage(systemName: "tray.and.arrow.down"))
	private let messageLabel = UILabel()

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemBackground

		imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .largeTitle)
		imageView.tintColor = .secondaryLabel

		messageLabel.text = NSLocalizedString("Saving to NetNewsList…", comment: "Share extension: saving")
		messageLabel.font = .preferredFont(forTextStyle: .headline)
		messageLabel.adjustsFontForContentSizeCategory = true
		messageLabel.textAlignment = .center
		messageLabel.numberOfLines = 0

		let stack = UIStackView(arrangedSubviews: [imageView, messageLabel])
		stack.axis = .vertical
		stack.alignment = .center
		stack.spacing = 12
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
			stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
		])

		let inputItems = extensionContext?.inputItems ?? []
		Task { @MainActor in
			await save(inputItems)
		}
	}
}

private extension ShareViewController {

	func save(_ inputItems: [Any]) async {
		guard let item = await SharedPageResolver.resolveItem(inputItems) else {
			finish(NSLocalizedString("There’s nothing to save to NetNewsList.", comment: "Share extension: nothing to save"), symbolName: "exclamationmark.triangle", succeeded: false)
			return
		}
		do {
			let request: SavedArticleRequest
			switch item {
			case .webPage(let page):
				request = SavedArticleRequest(url: page.url.absoluteString, title: page.title, body: page.body)
			case .document(let document):
				var stagedFileName: String?
				if let fileURL = document.fileURL {
					stagedFileName = try SavedArticleInbox.stageImportedFile(from: fileURL)
				} else if let data = document.data {
					let ext = document.contentTypeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "dat"
					stagedFileName = try SavedArticleInbox.stageImportedData(data, fileExtension: ext)
				}
				request = SavedArticleRequest(url: nil,
											  title: document.title,
											  body: document.body,
											  importedFileName: stagedFileName,
											  contentTypeIdentifier: document.contentTypeIdentifier)
			}
			try SavedArticleInbox.add(request)
			finish(NSLocalizedString("Saved to NetNewsList", comment: "Share extension: saved"), symbolName: "checkmark.circle", succeeded: true)
		} catch {
			Self.logger.error("ShareViewController: couldn’t save shared item: \(error.localizedDescription, privacy: .public)")
			finish(NSLocalizedString("Couldn’t save to NetNewsList. Open the app to add or import it.", comment: "Share extension: failed"), symbolName: "exclamationmark.triangle", succeeded: false)
		}
	}

	func finish(_ message: String, symbolName: String, succeeded: Bool) {
		messageLabel.text = message
		imageView.image = UIImage(systemName: symbolName)
		imageView.tintColor = succeeded ? .systemGreen : .systemOrange
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(succeeded ? 700 : 2000))
			self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
		}
	}
}
