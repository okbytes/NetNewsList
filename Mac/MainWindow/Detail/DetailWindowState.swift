//
//  DetailWindowState.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 12/16/23.
//  Copyright © 2023 Ranchero Software. All rights reserved.
//

import Foundation

final class DetailWindowState: NSObject, NSSecureCoding {

	static let supportsSecureCoding = true

	let windowScrollY: CGFloat

	init(windowScrollY: CGFloat) {
		self.windowScrollY = windowScrollY
	}

	private struct Key {
		static let windowScrollY = "windowScrollY"
	}

	required init?(coder: NSCoder) {
		windowScrollY = CGFloat(coder.decodeDouble(forKey: Key.windowScrollY))
	}

	func encode(with coder: NSCoder) {
		coder.encode(Double(windowScrollY), forKey: Key.windowScrollY)
	}

	override var description: String {
		"DetailWindowState: scrollY=\(windowScrollY)"
	}
}
