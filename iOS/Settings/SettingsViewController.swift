//
//  SettingsViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/24/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import SwiftUI
import RSCore
import Account
import ActivityLog

final class SettingsViewController: UITableViewController {

	// These enums match the sections and rows of the static table in Settings.storyboard.
	// The Timeline section holds only the Sort Oldest to Newest switch.
	private enum Section: Int {
		case timeline = 0
		case articles = 1
		case troubleshooting = 2
	}

	private enum TroubleshootingRow: Int {
		case errorLog = 0
		case activityLog = 1
		case resetiCloudSync = 2
	}

	private enum ArticlesRow: Int {
		case xAccount = 0
	}

	@IBOutlet var timelineSortOrderSwitch: UISwitch!
	@IBOutlet var xAccountDetailLabel: UILabel!

	weak var presentingParentController: UIViewController?

	override func viewDidLoad() {
		// This hack mostly works around a bug in static tables with dynamic type.  See: https://spin.atomicobject.com/2018/10/15/dynamic-type-static-uitableview/
		NotificationCenter.default.removeObserver(tableView!, name: UIContentSizeCategory.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryDidChange), name: UIContentSizeCategory.didChangeNotification, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(xAccountSignInStateDidChange(_:)), name: .XAccountSignInStateDidChange, object: nil)

		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 44
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		if AppDefaults.shared.timelineSortDirection == .orderedAscending {
			timelineSortOrderSwitch.isOn = true
		} else {
			timelineSortOrderSwitch.isOn = false
		}

		updateXAccountDetailLabel()

		let buildLabel = NonIntrinsicLabel(frame: CGRect(x: 32.0, y: 0.0, width: 0.0, height: 0.0))
		buildLabel.font = UIFont.systemFont(ofSize: 11.0)
		buildLabel.textColor = UIColor.gray
		buildLabel.text = "\(Bundle.main.appName) \(Bundle.main.versionNumber) (Build \(Bundle.main.buildNumber))"
		buildLabel.sizeToFit()
		buildLabel.translatesAutoresizingMaskIntoConstraints = false

		let wrapperView = UIView(frame: CGRect(x: 0, y: 0, width: buildLabel.frame.width, height: buildLabel.frame.height + 10.0))
		wrapperView.translatesAutoresizingMaskIntoConstraints = false
		wrapperView.addSubview(buildLabel)
		tableView.tableFooterView = wrapperView

	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		self.tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
	}

	// MARK: UITableView

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {

		switch Section(rawValue: indexPath.section) {
		case .articles:
			switch ArticlesRow(rawValue: indexPath.row) {
			case .xAccount:
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
				signInOrOutOfX()
			default:
				break
			}
		case .troubleshooting:
			if TroubleshootingRow(rawValue: indexPath.row) == .resetiCloudSync {
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
				confirmResetiCloudSync()
				return
			}
			let viewController: UIViewController? = {
				switch TroubleshootingRow(rawValue: indexPath.row) {
				case .errorLog:
					return UIHostingController(rootView: ErrorLogView())
				case .activityLog:
					return UIHostingController(rootView: ActivityLogView())
				default:
					return nil
				}
			}()
			if let viewController {
				self.navigationController?.pushViewController(viewController, animated: true)
			}
		default:
			tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
		}
	}

	override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
		return false
	}

	override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
		return false
	}

	override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
		return .none
	}

	override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
		return UITableView.automaticDimension
	}

	// MARK: Actions

	@IBAction func done(_ sender: Any) {
		dismiss(animated: true)
	}

	@IBAction func switchTimelineOrder(_ sender: Any) {
		if timelineSortOrderSwitch.isOn {
			AppDefaults.shared.timelineSortDirection = .orderedAscending
		} else {
			AppDefaults.shared.timelineSortDirection = .orderedDescending
		}
	}

	// MARK: - Notifications

	@objc func contentSizeCategoryDidChange() {
		tableView.reloadData()
	}

}

// MARK: - Private

private extension SettingsViewController {

	func confirmResetiCloudSync() {
		let title = NSLocalizedString("Reset iCloud Sync?", comment: "Reset iCloud Sync alert title")
		let message = NSLocalizedString("NetNewsList will download everything from iCloud again, then upload any article on this device that iCloud doesn’t have. Nothing is deleted.", comment: "Reset iCloud Sync alert message")
		let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button"), style: .cancel))
		alertController.addAction(UIAlertAction(title: NSLocalizedString("Reset", comment: "Reset button"), style: .destructive) { [weak self] _ in
			Task { @MainActor in
				do {
					try await AccountManager.shared.defaultAccount.resetiCloudSync()
				} catch {
					self?.presentError(error)
				}
			}
		})
		present(alertController, animated: true)
	}

	/// Signed out, shows X's sign-in page; signed in, offers to sign out. X shows some posts only to signed-in people.
	func signInOrOutOfX() {
		guard XAccount.shared.isSignedIn else {
			let navigationController = UINavigationController(rootViewController: XSignInViewController())
			present(navigationController, animated: true)
			return
		}
		let title = NSLocalizedString("Sign Out of X?", comment: "Sign out of X alert title")
		let message = NSLocalizedString("Posts that X shows only to signed-in people won’t be saved from this device until you sign in again.", comment: "Sign out of X alert message")
		let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button"), style: .cancel))
		alertController.addAction(UIAlertAction(title: NSLocalizedString("Sign Out", comment: "Sign Out button"), style: .destructive) { _ in
			Task { @MainActor in
				await XAccount.shared.signOut()
			}
		})
		present(alertController, animated: true)
	}

	func updateXAccountDetailLabel() {
		xAccountDetailLabel.text = XAccount.shared.isSignedIn ? NSLocalizedString("Signed In", comment: "X account state") : NSLocalizedString("Not Signed In", comment: "X account state")
	}

	@objc func xAccountSignInStateDidChange(_ note: Notification) {
		updateXAccountDetailLabel()
	}
}
