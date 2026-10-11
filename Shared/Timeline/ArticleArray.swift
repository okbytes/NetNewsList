//
//  ArticleArray.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 11/1/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import Foundation
import Articles

typealias ArticleArray = [Article]

@MainActor extension Array where Element == Article {

	func articleAtRow(_ row: Int) -> Article? {
		if row < 0 || row == NSNotFound || row > count - 1 {
			return nil
		}
		return self[row]
	}

	func article(matching articleSpecifier: ArticleSpecifier) -> Article? {
		first { articleSpecifier.matchesArticle($0) }
	}

	func articlesForIndexes(_ indexes: IndexSet) -> [Article] {
		return indexes.compactMap { (oneIndex) -> Article? in
			return articleAtRow(oneIndex)
		}
	}

	func sortedByDate(_ sortDirection: ComparisonResult, groupByFeed: Bool = false) -> ArticleArray {
		return ArticleSorter.sortedByDate(articles: self, sortDirection: sortDirection, groupByFeed: groupByFeed)
	}

	func sorted(by parameters: ArticleSortParameters) -> ArticleArray {
		ArticleSorter.sorted(articles: self, parameters: parameters)
	}

	func canMarkAllAsRead() -> Bool {
		return anyArticleIsUnread()
	}

	func anyArticlePassesTest(_ test: ((Article) -> Bool)) -> Bool {
		for article in self {
			if test(article) {
				return true
			}
		}
		return false
	}

	func anyArticleIsReadAndCanMarkUnread() -> Bool {
		return anyArticlePassesTest { $0.status.read && $0.isAvailableToMarkUnread }
	}

	func anyArticleIsUnread() -> Bool {
		return anyArticlePassesTest { !$0.status.read }
	}

	func unreadArticles() -> [Article]? {
		let articles = self.filter { !$0.status.read }
		return articles.isEmpty ? nil : articles
	}

	func representSameArticlesInSameOrder(as otherArticles: [Article]) -> Bool {
		if self.count != otherArticles.count {
			return false
		}
		var i = 0
		for article in self {
			let otherArticle = otherArticles[i]
			if article.account != otherArticle.account || article.articleID != otherArticle.articleID {
				return false
			}
			i += 1
		}
		return true
	}
}
