//
//  CloudKitArticleStatusUpdate.swift
//  Account
//
//  Created by Maurice Parker on 4/29/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import SyncDatabase
import Articles

struct CloudKitArticleStatusUpdate {

	enum Record {
		case all
		case new
		case statusOnly
		case delete
	}

	var articleID: String
	var statuses: [SyncStatus]
	var article: Article?

	init?(articleID: String, statuses: [SyncStatus], article: Article?) {
		self.articleID = articleID
		self.statuses = statuses
		self.article = article

		let rec = record
		// This is an invalid status update.  The article is required for new and all
		if article == nil && (rec == .all || rec == .new) {
			return nil
		}
	}

	var record: Record {
		if statuses.contains(where: { $0.key == .deleted }) {
			// Deleted here, then saved again before the delete went: deleting removes the article
			// at once, so it exists here again only because of that save, which is newer. It goes up
			// as a full upload (unread, with its new saved date) instead of the delete.
			if article != nil && statuses.contains(where: { $0.key == .new }) {
				return .all
			}
			return .delete
		}

		// A first upload is saved only if the records don’t exist yet, so two devices (or the
		// browser extension) saving the same page don’t overwrite each other. That holds when a
		// status change or a body is queued with it too (saved, then archived or extracted before
		// it was sent): the status goes as a status update (`sendsStatus`), and a copy already in
		// iCloud is merged in rather than overwritten (`ArticleRecordPlan.contentUploads`).
		if statuses.contains(where: { $0.key == .new }) {
			return .new
		}

		// New content after the first upload: upload status and content, overwriting the server
		// copy. A pure status change never touches content.
		if statuses.contains(where: { $0.key == .content }) {
			return .all
		}

		return .statusOnly
	}

	/// Whether a read or starred change is queued, which a first upload sends as a status update.
	var sendsStatus: Bool {
		statuses.contains { $0.key == .read || $0.key == .starred }
	}

	var isRead: Bool {
		if let article = article {
			return article.status.read
		}
		return true
	}

	var isStarred: Bool {
		if let article = article {
			return article.status.starred
		}
		return false
	}

}
