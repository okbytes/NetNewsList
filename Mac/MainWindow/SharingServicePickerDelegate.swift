//
//  SharingServicePickerDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 2/17/18.
//  Copyright © 2018 Ranchero Software. All rights reserved.
//

import AppKit
import RSCore

@objc final class SharingServicePickerDelegate: NSObject, @MainActor NSSharingServicePickerDelegate {

	private let sharingServiceDelegate: SharingServiceDelegate

	init(_ window: NSWindow?) {
		sharingServiceDelegate = SharingServiceDelegate(window)
	}

	@MainActor func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
		proposedServices.filter { $0.menuItemTitle != "NetNewsWire" }
	}

	func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
		return sharingServiceDelegate
	}
}
