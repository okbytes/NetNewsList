//
//  AddAccountView.swift
//  NetNewsWire-iOS
//
//  Created by Brent Simmons on 9/18/26.
//

import SwiftUI
import Account

/// The list of account types the user picks from. Pushed onto the Settings navigation stack.
struct AddAccountView: View {

	/// Called after an account is added so the host can pop this screen.
	let didAddAccount: () -> Void

	@State private var presentedSheet: AccountSheet?

	private static let iconSize: CGFloat = 25
	private static let rowSpacing: CGFloat = 16

	private enum AccountGroup: Int, CaseIterable {
		case local
		case icloud

		var header: String {
			switch self {
			case .local:
				return NSLocalizedString("Local", comment: "Local Account")
			case .icloud:
				return NSLocalizedString("iCloud", comment: "iCloud Account")
			}
		}

		var footer: String {
			switch self {
			case .local:
				return NSLocalizedString("Local accounts do not sync your feeds across devices.", comment: "Local")
			case .icloud:
				return NSLocalizedString("Your iCloud account syncs your feeds across your Mac and iOS devices.", comment: "iCloud Account")
			}
		}

		var accountTypes: [AccountType] {
			switch self {
			case .local:
				return [.onMyMac]
			case .icloud:
				return [.cloudKit]
			}
		}
	}

	private struct AccountSheet: Identifiable {
		let accountType: AccountType

		var id: Int {
			accountType.rawValue
		}
	}

	var body: some View {
		List {
			ForEach(visibleGroups, id: \.self) { group in
				Section {
					ForEach(visibleAccountTypes(in: group), id: \.rawValue) { accountType in
						accountRow(accountType)
					}
				} header: {
					Text(group.header)
				} footer: {
					Text(group.footer)
				}
			}
		}
		.navigationTitle(NSLocalizedString("Add Account", comment: "Add Account"))
		.sheet(item: $presentedSheet) { sheet in
			switch sheet.accountType {
			case .onMyMac:
				LocalAccountView(didAddAccount: didAddAccount)
			case .cloudKit:
				CloudKitAccountView(didAddAccount: didAddAccount)
			}
		}
	}

	private func accountRow(_ accountType: AccountType) -> some View {
		Button {
			select(accountType)
		} label: {
			HStack(spacing: Self.rowSpacing) {
				Image(uiImage: Assets.accountImage(accountType))
					.resizable()
					.scaledToFit()
					.frame(width: Self.iconSize, height: Self.iconSize)
				Text(verbatim: accountType.displayName)
			}
		}
		.foregroundStyle(.primary)
		.disabled(isDisabled(accountType))
	}

	/// Groups with at least one account type to show. Developer builds hide the restricted types, as the Mac app does.
	private var visibleGroups: [AccountGroup] {
		AccountGroup.allCases.filter { !visibleAccountTypes(in: $0).isEmpty }
	}

	private func visibleAccountTypes(in group: AccountGroup) -> [AccountType] {
		group.accountTypes.filter { !(AppDefaults.shared.isDeveloperBuild && $0.isDeveloperRestricted) }
	}

	private func isDisabled(_ accountType: AccountType) -> Bool {
		accountType == .cloudKit && AccountManager.shared.hasiCloudAccount
	}

	private func select(_ accountType: AccountType) {
		presentedSheet = AccountSheet(accountType: accountType)
	}
}
