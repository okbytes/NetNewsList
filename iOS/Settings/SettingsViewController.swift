//
//  SettingsViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 4/24/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import SafariServices
import SwiftUI
import RSCore
import Account
import ActivityLog

final class SettingsViewController: UITableViewController {

	// These enums match the sections and rows of the static table in Settings.storyboard.
	private enum Section: Int {
		case timeline = 0
		case articles = 1
		case appearance = 2
		case troubleshooting = 3
		case help = 4
	}

	private enum TroubleshootingRow: Int {
		case errorLog = 0
		case activityLog = 1
		case resetiCloudSync = 2
	}

	private enum TimelineRow: Int {
		case sortOrder = 0
		case groupBySite = 1
		case confirmMarkAllAsRead = 2
		case timelineLayout = 3
	}

	private enum ArticlesRow: Int, CaseIterable {
		case theme = 0
		case openLinksInNetNewsWire = 1
		case enableFullScreenArticles = 2
	}

	private enum HelpRow: Int {
		case help = 0
		case forum = 1
		case releaseNotes = 2
		case bugTracker = 3
		case about = 4
	}

	@IBOutlet var timelineSortOrderSwitch: UISwitch!
	@IBOutlet var groupBySiteSwitch: UISwitch!
	@IBOutlet var articleThemeDetailLabel: UILabel!
	@IBOutlet var confirmMarkAllAsReadSwitch: UISwitch!
	@IBOutlet var showFullscreenArticlesSwitch: UISwitch!
	@IBOutlet var colorPaletteCell: UITableViewCell?
	@IBOutlet var unreadCountDisplayCell: UITableViewCell?
	@IBOutlet var openLinksInNetNewsWire: UISwitch!

	var scrollToArticlesSection = false
	weak var presentingParentController: UIViewController?

	private lazy var colorPalettePopUpButton = Self.makePopUpButton()
	private lazy var unreadCountDisplayPopUpButton = Self.makePopUpButton()

	override func viewDidLoad() {
		// This hack mostly works around a bug in static tables with dynamic type.  See: https://spin.atomicobject.com/2018/10/15/dynamic-type-static-uitableview/
		NotificationCenter.default.removeObserver(tableView!, name: UIContentSizeCategory.didChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(contentSizeCategoryDidChange), name: UIContentSizeCategory.didChangeNotification, object: nil)

		NotificationCenter.default.addObserver(self, selector: #selector(handleUserInterfaceColorPaletteDidUpdate(_:)), name: .userInterfaceColorPaletteDidUpdate, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleUnreadCountDisplaySettingDidChange(_:)), name: .unreadCountDisplaySettingDidChange, object: nil)

		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 44

		addPopUpButton(colorPalettePopUpButton, to: colorPaletteCell)
		addPopUpButton(unreadCountDisplayPopUpButton, to: unreadCountDisplayCell)
		updateColorPalettePopUpButton()
		updateUnreadCountDisplayPopUpButton()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		if AppDefaults.shared.timelineSortDirection == .orderedAscending {
			timelineSortOrderSwitch.isOn = true
		} else {
			timelineSortOrderSwitch.isOn = false
		}

		// The setting keeps its original key; the timeline groups by site.
		groupBySiteSwitch.isOn = AppDefaults.shared.timelineGroupByFeed

		articleThemeDetailLabel.text = ArticleThemesManager.shared.currentTheme.name

		if AppDefaults.shared.confirmMarkAllAsRead {
			confirmMarkAllAsReadSwitch.isOn = true
		} else {
			confirmMarkAllAsReadSwitch.isOn = false
		}

		if AppDefaults.shared.articleFullscreenAvailable {
			showFullscreenArticlesSwitch.isOn = true
		} else {
			showFullscreenArticlesSwitch.isOn = false
		}

		openLinksInNetNewsWire.isOn = !AppDefaults.shared.useSystemBrowser

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

		if scrollToArticlesSection {
			tableView.scrollToRow(at: IndexPath(row: 0, section: Section.articles.rawValue), at: .top, animated: true)
			scrollToArticlesSection = false
		}

	}

	// MARK: UITableView

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {

		switch Section(rawValue: section) {
		case .articles:
			// The Full Screen Articles row is iPhone-only.
			return traitCollection.userInterfaceIdiom == .phone ? ArticlesRow.allCases.count : ArticlesRow.allCases.count - 1
		default:
			return super.tableView(tableView, numberOfRowsInSection: section)
		}
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {

		switch Section(rawValue: indexPath.section) {
		case .timeline:
			switch TimelineRow(rawValue: indexPath.row) {
			case .timelineLayout:
				let timeline = UIStoryboard.settings.instantiateController(ofType: TimelineCustomizerCollectionViewController.self)
				self.navigationController?.pushViewController(timeline, animated: true)
			default:
				break
			}
		case .articles:
			switch ArticlesRow(rawValue: indexPath.row) {
			case .theme:
				let articleThemes = UIStoryboard.settings.instantiateController(ofType: ArticleThemesTableViewController.self)
				self.navigationController?.pushViewController(articleThemes, animated: true)
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
		case .help:
			switch HelpRow(rawValue: indexPath.row) {
			case .help:
				openURL(HelpURL.helpHome.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .forum:
				openURL(HelpURL.discourse.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .releaseNotes:
				openURL(HelpURL.releaseNotes.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .bugTracker:
				openURL(HelpURL.bugTracker.rawValue)
				tableView.selectRow(at: nil, animated: true, scrollPosition: .none)
			case .about:
				let hosting = UIHostingController(rootView: AboutView())
				self.navigationController?.pushViewController(hosting, animated: true)
			default:
				break
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

	@IBAction func switchGroupBySite(_ sender: Any) {
		AppDefaults.shared.timelineGroupByFeed = groupBySiteSwitch.isOn
	}

	@IBAction func switchConfirmMarkAllAsRead(_ sender: Any) {
		if confirmMarkAllAsReadSwitch.isOn {
			AppDefaults.shared.confirmMarkAllAsRead = true
		} else {
			AppDefaults.shared.confirmMarkAllAsRead = false
		}
	}

	@IBAction func switchFullscreenArticles(_ sender: Any) {
		if showFullscreenArticlesSwitch.isOn {
			AppDefaults.shared.articleFullscreenAvailable = true
		} else {
			AppDefaults.shared.articleFullscreenAvailable = false
		}
	}

	@IBAction func switchBrowserPreference(_ sender: Any) {
		if openLinksInNetNewsWire.isOn {
			AppDefaults.shared.useSystemBrowser = false
		} else {
			AppDefaults.shared.useSystemBrowser = true
		}
	}

	// MARK: - Notifications

	@objc func contentSizeCategoryDidChange() {
		tableView.reloadData()
	}

	@objc func browserPreferenceDidChange() {
		tableView.reloadData()
	}

	@objc func handleUserInterfaceColorPaletteDidUpdate(_ notification: Notification) {
		updateColorPalettePopUpButton()
	}

	@objc func handleUnreadCountDisplaySettingDidChange(_ notification: Notification) {
		updateUnreadCountDisplayPopUpButton()
	}

}

// MARK: - Private

private extension SettingsViewController {

	static func makePopUpButton() -> UIButton {
		var configuration = UIButton.Configuration.plain()
		configuration.baseForegroundColor = .secondaryLabel
		let button = UIButton(configuration: configuration)
		button.showsMenuAsPrimaryAction = true
		button.changesSelectionAsPrimaryAction = true
		return button
	}

	/// Auto Layout lets the button resize itself when choosing an item changes its title.
	func addPopUpButton(_ button: UIButton, to cell: UITableViewCell?) {
		guard let cell else {
			return
		}
		button.translatesAutoresizingMaskIntoConstraints = false
		button.setContentCompressionResistancePriority(.required, for: .horizontal)
		cell.contentView.addSubview(button)
		NSLayoutConstraint.activate([
			button.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
			button.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor)
		])
	}

	func updateColorPalettePopUpButton() {
		let currentColorPalette = AppDefaults.userInterfaceColorPalette
		let actions = UserInterfaceColorPalette.allCases.map { colorPalette in
			UIAction(title: String(describing: colorPalette), state: colorPalette == currentColorPalette ? .on : .off) { _ in
				AppDefaults.userInterfaceColorPalette = colorPalette
			}
		}
		colorPalettePopUpButton.menu = UIMenu(children: actions)
	}

	func updateUnreadCountDisplayPopUpButton() {
		let currentUnreadCountDisplay = AppDefaults.shared.unreadCountDisplay
		let actions = UnreadCountDisplay.allCases.map { unreadCountDisplay in
			UIAction(title: String(describing: unreadCountDisplay), state: unreadCountDisplay == currentUnreadCountDisplay ? .on : .off) { _ in
				AppDefaults.shared.unreadCountDisplay = unreadCountDisplay
			}
		}
		unreadCountDisplayPopUpButton.menu = UIMenu(children: actions)
	}

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

	func openURL(_ urlString: String) {
		guard let url = URL(string: urlString) else {
			return
		}

		// Open GitHub links in the GitHub app when installed.
		if let host = url.host, host == "github.com" || host.hasSuffix(".github.com") {
			UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { [weak self] openedInApp in
				if !openedInApp {
					self?.presentSafariViewController(for: url)
				}
			}
			return
		}

		presentSafariViewController(for: url)
	}

	private func presentSafariViewController(for url: URL) {
		let vc = SFSafariViewController(url: url)
		vc.modalPresentationStyle = .pageSheet
		present(vc, animated: true)
	}
}
