//
//  WidgetDeepLinks.swift
//  NetNewsWire
//
//  Created by Stuart Breckenridge on 18/11/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation

enum WidgetDeepLink {

	case queue
	case queueArticle(id: String)

	var url: URL {
		switch self {
		case .queue:
			return URL(string: "nnw://showqueue")!
		case .queueArticle(let articleID):
			var url = URLComponents(url: WidgetDeepLink.queue.url, resolvingAgainstBaseURL: false)!
			url.queryItems = [URLQueryItem(name: "id", value: articleID)]
			return url.url!
		}
	}

}
