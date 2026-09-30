//
//  ArticleExtractor.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 9/18/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import Foundation

public enum ArticleExtractorState: Sendable {
	case ready
	case processing
	case failedToParse
	case complete
	case cancelled
}

@MainActor protocol ArticleExtractorDelegate {
	func articleExtractionDidFail(with: Error)
	func articleExtractionDidComplete(extractedArticle: ExtractedArticle)
}

/// Placeholder until on-device extraction replaces Reader View (Technotes/NetNewsList/Plan.md, PR7).
/// The Feedbin extraction service this used to call needs private keys this app does not have,
/// so the initializer always fails and callers treat extraction as unavailable.
@MainActor final class ArticleExtractor {
	let articleLink: String
	let delegate: ArticleExtractorDelegate
	var article: ExtractedArticle?
	var state = ArticleExtractorState.ready

	init?(_ articleLink: String, delegate: ArticleExtractorDelegate) {
		return nil
	}

	func process() {
	}

	func cancel() {
		state = .cancelled
	}
}
