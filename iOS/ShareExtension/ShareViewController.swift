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
		guard let page = await SharedPageResolver.resolve(inputItems) else {
			finish(NSLocalizedString("There’s no web page to save.", comment: "Share extension: nothing to save"), symbolName: "exclamationmark.triangle", succeeded: false)
			return
		}
		do {
			try SavedArticleInbox.add(SavedArticleRequest(url: page.url.absoluteString, title: page.title, body: page.body))
			finish(NSLocalizedString("Saved to NetNewsList", comment: "Share extension: saved"), symbolName: "checkmark.circle", succeeded: true)
		} catch {
			Self.logger.error("ShareViewController: couldn’t save \(page.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
			finish(NSLocalizedString("Couldn’t save the page. Open NetNewsList and use Add Article.", comment: "Share extension: failed"), symbolName: "exclamationmark.triangle", succeeded: false)
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
