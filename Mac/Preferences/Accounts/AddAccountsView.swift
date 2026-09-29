//
//  AddAccountsView.swift
//  NetNewsWire
//
//  Created by Stuart Breckenridge on 28/10/20.
//  Copyright © 2020 Ranchero Software. All rights reserved.
//

import SwiftUI
import Account
import RSCore

enum AddAccountSections: Int, CaseIterable {
	case local = 0
	case icloud
	case allOrdered

	var sectionHeader: String {
		switch self {
		case .local:
			return NSLocalizedString("Local", comment: "Local Account")
		case .icloud:
			return NSLocalizedString("iCloud", comment: "iCloud Account")
		case .allOrdered:
			return ""
		}
	}

	var sectionFooter: String {
		switch self {
		case .local:
			return NSLocalizedString("Local accounts do not sync feeds across devices", comment: "Local Account")
		case .icloud:
			return NSLocalizedString("Your iCloud account syncs your feeds across your Mac and iOS devices", comment: "iCloud Account")
		case .allOrdered:
			return ""
		}
	}

	var sectionContent: [AccountType] {
		switch self {
		case .local:
			return [.onMyMac]
		case .icloud:
			return [.cloudKit]
		case .allOrdered:
			return AddAccountSections.local.sectionContent +
			AddAccountSections.icloud.sectionContent
		}
	}
}

struct AddAccountsView: View {

	weak var parent: NSHostingController<AddAccountsView>? // required because presentationMode.dismiss() doesn't work
	var addAccountDelegate: AccountsPreferencesAddAccountDelegate?
	@State private var selectedAccount: AccountType = .onMyMac

	init(delegate: AccountsPreferencesAddAccountDelegate?) {
		self.addAccountDelegate = delegate
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Choose an account type to add…")
				.font(.headline)
				.padding()

			localAccount

			icloudAccount


			HStack(spacing: 12) {
				Spacer()
				Button(action: {
					parent?.dismiss(nil)
				}, label: {
					Text("Cancel", comment: "Cancel button")
						.frame(width: 76)
				})
				.help(Text("Cancel", comment: "Cancel button"))
				.keyboardShortcut(.cancelAction)
				Button(action: {
					addAccountDelegate?.presentSheetForAccount(selectedAccount)
					parent?.dismiss(nil)
				}, label: {
					Text("Continue")
						.frame(width: 76)
				})
				.help("Add Account")
				.keyboardShortcut(.defaultAction)
			}
			.padding(.top, 12)
			.padding(.bottom, 4)
		}
		.pickerStyle(RadioGroupPickerStyle())
		.fixedSize(horizontal: false, vertical: true)
		.frame(width: 420)
		.padding()
    }

	var localAccount: some View {
		VStack(alignment: .leading) {
			Text("Local")
				.font(.headline)
				.padding(.horizontal)

			Picker(selection: $selectedAccount, label: Text(""), content: {
				ForEach(AddAccountSections.local.sectionContent, id: \.self, content: { account in
					HStack(alignment: .center) {
						account.image()
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20, alignment: .center)
							.padding(.leading, 4)
						Text(account.displayName)
					}
					.tag(account)
				})
			})
			.pickerStyle(RadioGroupPickerStyle())
			.offset(x: 7.5, y: 0)

			Text(AddAccountSections.local.sectionFooter).foregroundColor(.gray)
				.padding(.horizontal)
				.lineLimit(3)
				.fixedSize(horizontal: false, vertical: true)

		}

	}

	var icloudAccount: some View {
		VStack(alignment: .leading) {
			Text("iCloud")
				.font(.headline)
				.padding(.horizontal)
				.padding(.top, 8)

			Picker(selection: $selectedAccount, label: Text(""), content: {
				ForEach(AddAccountSections.icloud.sectionContent, id: \.self, content: { account in
					HStack(alignment: .center) {
						account.image()
							.resizable()
							.scaledToFit()
							.frame(width: 20, height: 20, alignment: .center)
							.padding(.leading, 4)

						Text(account.displayName)
					}
					.tag(account)
				})
			})
			.offset(x: 7.5, y: 0)
			.disabled(AccountManager.shared.hasiCloudAccount)

			Text(AddAccountSections.icloud.sectionFooter).foregroundColor(.gray)
				.padding(.horizontal)
				.lineLimit(3)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

struct AddAccountsView_Previews: PreviewProvider {
	static var previews: some View {
		AddAccountsView(delegate: nil)
	}
}
