//
//  ArticleDeletion.swift
//  NetNewsList
//
//  Deleting is permanent and reaches every device, so it always asks first.
//

import AppKit
import Articles
import Account

@MainActor enum ArticleDeletion {

	static func confirmAndDelete(_ articles: [Article], in window: NSWindow) {
		guard !articles.isEmpty else {
			return
		}
		let alert = NSAlert()
		alert.alertStyle = .warning
		if articles.count == 1, let article = articles.first {
			let name = ArticleStringFormatter.shared.truncatedTitle(article)
			alert.messageText = String(format: NSLocalizedString("Delete “%@”?", comment: "Delete article alert"), name)
		} else {
			alert.messageText = String(format: NSLocalizedString("Delete %ld articles?", comment: "Delete articles alert"), articles.count)
		}
		alert.informativeText = NSLocalizedString("They’re removed from NetNewsList on all your devices. You can’t undo this.", comment: "Delete articles alert")
		let deleteButton = alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Delete button"))
		deleteButton.hasDestructiveAction = true
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

		let articleIDs = Set(articles.map(\.articleID))
		alert.beginSheetModal(for: window) { response in
			guard response == .alertFirstButtonReturn else {
				return
			}
			Task { @MainActor in
				await AccountManager.shared.defaultAccount.deleteArticles(articleIDs: articleIDs)
			}
		}
	}
}
