//
//  AccountType+Helpers.swift
//  NetNewsWire
//
//  Created by Stuart Breckenridge on 27/10/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import Foundation
import Account
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

extension AccountType {

	// MARK: - Log Colors

	#if os(macOS)
	var logColor: NSColor {
		switch self {
		case .cloudKit:
			return .systemPurple
		}
	}
	#else
	var logColor: Color {
		switch self {
		case .cloudKit:
			return .purple
		}
	}
	#endif

	// MARK: - SwiftUI Images
	@MainActor func image() -> Image {
		switch self {
		case .cloudKit:
			return Image("accountCloudKit")
		}
	}

}
