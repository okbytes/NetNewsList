//
//  AppDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/11/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import UserNotifications
import os
import Articles
import Account
import ActivityLog
import ErrorLog
import RSCore
import RSCoreObjC
import RSCoreResources
import RSWeb
import Images
import HTMLMetadata

let appName = "NetNewsList"

@MainActor var appDelegate: AppDelegate!

@main
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSUserInterfaceValidations, UNUserNotificationCenterDelegate, UnreadCountProvider {

	static private let logger = Logger(subsystem: Logger.nnwSubsystem, category: "AppDelegate")

	private struct WindowRestorationIdentifiers {
		static let mainWindow = "mainWindow"
	}

	private var shuttingDown = false {
		didSet {
			if shuttingDown {
				ArticleStatusSyncTimer.shared.stop()
			}
		}
	}

	private var isShutDownSyncDone = false

	@IBOutlet var debugMenuItem: NSMenuItem!
	@IBOutlet var useColumnLayoutMenuItem: NSMenuItem!

	var unreadCount = 0 {
		didSet {
			if unreadCount != oldValue {
//				MainActor.assumeIsolated {
					CoalescingQueue.standard.add(self, #selector(updateDockBadge))
					postUnreadCountDidChangeNotification()
//				}
			}
		}
	}

	private var mainWindowController: MainWindowController? {
		var bestController: MainWindowController?
		for candidateController in mainWindowControllers {
			if let bestWindow = bestController?.window, let candidateWindow = candidateController.window {
				if bestWindow.orderedIndex > candidateWindow.orderedIndex {
					bestController = candidateController
				}
			} else {
				bestController = candidateController
			}
		}
		return bestController
	}

	private var mainWindowControllers = [MainWindowController]()
	private lazy var preferencesWindowController = PreferencesWindowController()
	private var aboutWindowController: AboutWindowController?
	private var addFeedController: AddFeedController?
	private var addFolderWindowController: AddFolderWindowController?
	private var keyboardShortcutsWindowController: WebViewWindowController?
	private var inspectorWindowController: InspectorWindowController?
	private var activityWindowController: CurrentActivityWindowController?
	private var activityLogWindowController: ActivityLogWindowController?
	private var errorLogWindowController: ErrorLogWindowController?
	private let appMovementMonitor: RSAppMovementMonitor

	private var themeImportPath: String?

	@MainActor override init() {
		NSMenuItem.rs_disableIcons()
		NSWindow.allowsAutomaticWindowTabbing = false
		self.appMovementMonitor = RSAppMovementMonitor()
		super.init()

		appDelegate = self
		AccountManager.shared.start()

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: AccountManager.shared)
		NotificationCenter.default.addObserver(self, selector: #selector(inspectableObjectsDidChange(_:)), name: .InspectableObjectsDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(importDownloadedTheme(_:)), name: .didEndDownloadingTheme, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(themeImportError(_:)), name: .didFailToImportThemeWithError, object: nil)
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWakeNotification(_:)), name: NSWorkspace.didWakeNotification, object: nil)
	}

	// MARK: - API

	func showAddFolderSheetOnWindow(_ window: NSWindow) {
		addFolderWindowController = AddFolderWindowController()
		addFolderWindowController!.runSheetOnWindow(window)
	}

	func showAddFeedSheetOnWindow(_ window: NSWindow, urlString: String?, name: String?, account: Account?, folder: Folder?) {
		addFeedController = AddFeedController(hostWindow: window)
		addFeedController?.showAddFeedSheet(urlString, name, account, folder)
	}

	// MARK: - NSApplicationDelegate

	func applicationWillFinishLaunching(_ notification: Notification) {
		FaviconGenerator.templateImage = Assets.Images.faviconTemplate

		installAppleEventHandlers()

		CacheCleaner.purgeIfNecessary()

		// Try to establish a cache in the Caches folder, but if it fails for some reason fall back to a temporary dir
		let cacheFolder: String
		if let userCacheFolder = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false).path {
			cacheFolder = userCacheFolder
		} else {
			let bundleIdentifier = (Bundle.main.infoDictionary!["CFBundleIdentifier"]! as! String)
			cacheFolder = (NSTemporaryDirectory() as NSString).appendingPathComponent(bundleIdentifier)
		}

		let imagesFolder = (cacheFolder as NSString).appendingPathComponent("Images")
		let imagesFolderURL = URL(fileURLWithPath: imagesFolder)
		try! FileManager.default.createDirectory(at: imagesFolderURL, withIntermediateDirectories: true, attributes: nil)
	}

	func applicationDidFinishLaunching(_ note: Notification) {

		WebViewConfiguration.resolveBrowserUserAgent()
		Task {
			await WebViewConfiguration.compileContentBlockingRules()
		}

		// Load now, while the app bundle is readable. A translocated app that gets moved can’t read it later.
		_ = MainWindowKeyboardHandler.shared

		AppDefaults.shared.registerDefaults()
		let isFirstRun = AppDefaults.shared.isFirstRun
		if isFirstRun {
			Self.logger.debug("Is first run.")
		}
		updateColumnLayoutMenuItem()

		if mainWindowController == nil {
			let mainWindowController = createAndShowMainWindow()
			mainWindowController.restoreStateFromUserDefaults()
		}

		if isFirstRun {
			mainWindowController?.window?.center()
		}

		NotificationCenter.default.addObserver(self, selector: #selector(feedSettingDidChange(_:)), name: .feedSettingDidChange, object: nil)
		NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated {
				self.userDefaultsDidChange()
			}
		}

		DispatchQueue.main.async {
			self.unreadCount = AccountManager.shared.unreadCount
		}

		if !Platform.isRunningUnitTests {
			if InspectorWindowController.shouldOpenAtStartup {
				toggleInspectorWindow(self)
			}
			if CurrentActivityWindowController.shouldOpenAtStartup {
				showActivityWindow(self)
			}
			if ActivityLogWindowController.shouldOpenAtStartup {
				showActivityLog(self)
			}
			if ErrorLogWindowController.shouldOpenAtStartup {
				showErrorLog(self)
			}
		}

		ArticleThemesManager.shared.start()
		NetworkMonitor.shared.start()
		MemoryPressureMonitor.shared.start()

		if !Platform.isRunningUnitTests {
			ExtensionContainersFile.shared.start()
			ExtensionFeedAddRequestFile.shared.start()
		}

		ArticleStatusSyncTimer.shared.start()

		// Silent CloudKit pushes don’t need notification permission.
		NSApplication.shared.registerForRemoteNotifications()

		UNUserNotificationCenter.current().delegate = self

		#if DEBUG
		ArticleStatusSyncTimer.shared.update()
		#else
		if AppDefaults.shared.suppressSyncOnLaunch {
			ArticleStatusSyncTimer.shared.update()
		} else {
			DispatchQueue.main.async {
				ArticleStatusSyncTimer.shared.timedRefresh(nil)
			}
		}
		#endif

		if !AppDefaults.shared.showDebugMenu {
			debugMenuItem.menu?.removeItem(debugMenuItem)
		}
	}

	func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
		guard let mainWindowController else {
			return false
		}
		mainWindowController.handle(userActivity)
		return true
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		// https://github.com/brentsimmons/NetNewsWire/issues/522
		// I couldn’t reproduce the crashing bug, but it appears to happen on creating a main window
		// and its views and view controllers. The check below is so that the app does nothing
		// if the window doesn’t already exist — because it absolutely *should* exist already.
		// And if the window exists, then maybe the views and view controllers are also already loaded?
		// We’ll try this, and then see if we get more crash logs like this or not.
		guard let mainWindowController, mainWindowController.isWindowLoaded else {
			return false
		}
		// Only bring the main window forward when it’s been closed — leave it
		// alone if it’s already open (or miniaturized).
		if !mainWindowController.isOpen {
			mainWindowController.showWindow(self)
		}
		return false
	}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
		return true
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		fireOldTimers()
		AppNotification.postAppDidBecomeActive()
	}

	func applicationDidResignActive(_ notification: Notification) {
		AppNotification.postAppDidGoToBackground()
		saveState()
	}

	func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
		Task { @MainActor in
			await AccountManager.shared.receiveRemoteNotification(userInfo: userInfo)
		}
	}

	func application(_ sender: NSApplication, openFile filename: String) -> Bool {
		guard filename.hasSuffix(ArticleTheme.nnwThemeSuffix) else {
			return false
		}

		let url = URL(filePath: filename)
		importTheme(url: url)
		return true
	}

	func applicationWillTerminate(_ notification: Notification) {
		shuttingDown = true
		saveState()

		AccountManager.shared.saveAllIfNeeded()

		ArticleThemeDownloader.shared.cleanUp()

		Task { @MainActor in
			await AccountManager.shared.sendArticleStatusAll()
			isShutDownSyncDone = true
		}

		let timeout = Date().addingTimeInterval(2)
		while !isShutDownSyncDone && RunLoop.current.run(mode: .default, before: timeout) && timeout > Date() { }
	}

	// MARK: - Notifications

	@objc func unreadCountDidChange(_ note: Notification) {
		assert(note.object is AccountManager)
		unreadCount = AccountManager.shared.unreadCount
	}

	@objc func feedSettingDidChange(_ note: Notification) {
		MainActor.assumeIsolated {
			guard let feed = note.object as? Feed, let key = note.userInfo?[Feed.SettingUserInfoKey] as? Feed.SettingKey else {
				return
			}
			if key == .homePageURL || key == .faviconURL {
				_ = FaviconDownloader.shared.favicon(for: feed)
			}
		}
	}

	@objc func inspectableObjectsDidChange(_ note: Notification) {
		MainActor.assumeIsolated {
			guard let inspectorWindowController = inspectorWindowController, inspectorWindowController.isOpen else {
				return
			}
			inspectorWindowController.objects = objectsForInspector()
		}
	}

	func userDefaultsDidChange() {
		updateColumnLayoutMenuItem()

		updateDockBadge()
	}

	@objc func didWakeNotification(_ note: Notification) {
		Task { @MainActor in
			ArticleStatusSyncTimer.shared.fireOldTimer()
		}
	}

	@objc func importDownloadedTheme(_ note: Notification) {
		guard let userInfo = note.userInfo,
			let url = userInfo["url"] as? URL else {
			return
		}
		DispatchQueue.main.async {
			self.importTheme(url: url)
		}
	}

	// MARK: Main Window

	func createMainWindowController() -> MainWindowController {
		let controller = MainWindowController()

		if !(mainWindowController?.isOpen ?? false) {
			mainWindowControllers.removeAll()
		}
		mainWindowControllers.append(controller)
		return controller
	}

	@discardableResult
	func createAndShowMainWindow() -> MainWindowController {
		let controller = createMainWindowController()
		controller.showWindow(self)

		if let window = controller.window {
			window.restorationClass = Self.self
			window.identifier = NSUserInterfaceItemIdentifier(rawValue: WindowRestorationIdentifiers.mainWindow)
		}

		return controller
	}

	func createAndShowMainWindowIfNecessary() -> MainWindowController {
		if let mainWindowController {
			mainWindowController.showWindow(self)
			return mainWindowController
		}
		return createAndShowMainWindow()
	}

	func removeMainWindow(_ windowController: MainWindowController) {
		guard mainWindowControllers.count > 1 else { return }
		if let index = mainWindowControllers.firstIndex(of: windowController) {
			mainWindowControllers.remove(at: index)
		}
	}

	// MARK: NSUserInterfaceValidations
	func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
		if shuttingDown {
			return false
		}

		let isDisplayingSheet = mainWindowController?.isDisplayingSheet ?? false

		if item.action == #selector(refreshAll(_:)) {
			return !AccountManager.shared.refreshInProgress && !AccountManager.shared.activeAccounts.isEmpty
		}

		if item.action == #selector(showAddFeedWindow(_:)) || item.action == #selector(showAddFolderWindow(_:)) {
			return !isDisplayingSheet && !AccountManager.shared.activeAccounts.isEmpty
		}

		if item.action == #selector(toggleWebInspectorEnabled(_:)) {
			(item as! NSMenuItem).state = AppDefaults.shared.webInspectorEnabled ? .on : .off
		}

		return true
	}

	// MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {

		// Wrapper to safely transfer non-Sendable values to MainActor
		struct UnsafeSendable<T>: @unchecked Sendable {
			let value: T
		}

		let wrappedResponse = UnsafeSendable(value: response)
		let wrappedCompletionHandler = UnsafeSendable(value: completionHandler)

		Task { @MainActor in
			mainWindowController?.handle(wrappedResponse.value)
			wrappedCompletionHandler.value()
		}
    }

	// MARK: Add Feed
	@MainActor func addFeed(_ urlString: String?, name: String? = nil, account: Account? = nil, folder: Folder? = nil) {
		let windowController = createAndShowMainWindowIfNecessary()
		if windowController.isDisplayingSheet {
			return
		}

		showAddFeedSheetOnWindow(windowController.window!, urlString: urlString, name: name, account: account, folder: folder)
	}

	private func addFeedContainerFromSidebarSelection() -> Container? {
		guard let container = mainWindowController?.selectedContainerInSidebar() else {
			return nil
		}
		guard let account = container as? Account else {
			return container
		}
		return AddFeedDefaultContainer.substituteContainerIfNeeded(account: account)
	}

	// MARK: - Dock Badge
	@objc func updateDockBadge() {
		Task { @MainActor in
			let label = unreadCount > 0 ? "\(unreadCount)" : ""
			NSApplication.shared.dockTile.badgeLabel = label
		}
	}

	// MARK: - Actions
	@IBAction func showPreferences(_ sender: Any?) {
		preferencesWindowController.showWindow(self)
	}

	@IBAction func newMainWindow(_ sender: Any?) {
		createAndShowMainWindow()
	}

	@IBAction func showMainWindow(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.window?.makeKey()
	}

	@IBAction func showErrorLog(_ sender: Any?) {
		if errorLogWindowController == nil {
			errorLogWindowController = ErrorLogWindowController()
		}
		errorLogWindowController!.showWindow(self)
	}

	@objc func selectFeedInSidebar(_ sender: Any?) {
		guard let feed = sender as? Feed else {
			return
		}
		guard let mainWindowController else {
			return
		}
		mainWindowController.showWindow(self)
		mainWindowController.selectFeedInSidebar(feed)
	}

	@IBAction func showActivityWindow(_ sender: Any?) {
		if activityWindowController == nil {
			activityWindowController = CurrentActivityWindowController()
		}
		activityWindowController?.showWindow(self)
	}

	@IBAction func showActivityLog(_ sender: Any?) {
		if activityLogWindowController == nil {
			activityLogWindowController = ActivityLogWindowController()
		}
		activityLogWindowController?.showWindow(self)
	}

	@IBAction func refreshAll(_ sender: Any?) {
		AccountManager.shared.refreshAllWithoutWaiting(errorHandler: ErrorHandler.present)
	}

	@IBAction func showAddFeedWindow(_ sender: Any?) {
		let container = addFeedContainerFromSidebarSelection()
		addFeed(nil, account: container?.account, folder: container as? Folder)
	}

	@IBAction func showAddFolderWindow(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		showAddFolderSheetOnWindow(windowController.window!)
	}

	@IBAction func showKeyboardShortcutsWindow(_ sender: Any?) {
		if keyboardShortcutsWindowController == nil {

			keyboardShortcutsWindowController = WebViewWindowController(title: NSLocalizedString("Keyboard Shortcuts", comment: "window title"))
			let htmlFile = Bundle(for: type(of: self)).path(forResource: "KeyboardShortcuts", ofType: "html")!
			keyboardShortcutsWindowController?.displayContents(of: htmlFile)

			if let window = keyboardShortcutsWindowController?.window {
				let point = NSPoint(x: 128, y: 64)
				let size = NSSize(width: 620, height: 1100)
				let minSize = NSSize(width: 400, height: 400)
				window.setPointAndSizeAdjustingForScreen(point: point, size: size, minimumSize: minSize)
			}

		}

		keyboardShortcutsWindowController!.showWindow(self)
	}

	@IBAction func toggleInspectorWindow(_ sender: Any?) {
		if inspectorWindowController == nil {
			inspectorWindowController = InspectorWindowController()
		}

		if inspectorWindowController!.isOpen {
			inspectorWindowController!.window!.performClose(self)
		} else {
			inspectorWindowController!.objects = objectsForInspector()
			inspectorWindowController!.showWindow(self)
		}
	}

	@IBAction func openWebsite(_ sender: Any?) {
		HelpURL.website.open()
	}

	@IBAction func openReleaseNotes(_ sender: Any?) {
		HelpURL.releaseNotes.open()
	}

	@IBAction func openHowToSupport(_ sender: Any?) {
		HelpURL.howToSupportNetNewsWire.open()
	}

	@IBAction func openTechnotes(_ sender: Any?) {
		HelpURL.technotes.open()
	}

	@IBAction func openRepository(_ sender: Any?) {
		HelpURL.githubRepo.open()
	}

	@IBAction func openBugTracker(_ sender: Any?) {
		HelpURL.bugTracker.open()
	}

	@IBAction func openDiscourse(_ sender: Any?) {
		HelpURL.discourse.open()
	}

	@IBAction func showHelp(_ sender: Any?) {
		HelpURL.helpHome.open()
	}

	@IBAction func showPrivacyPolicy(_ sender: Any?) {
		HelpURL.privacyPolicy.open()
	}

	@IBAction func gotoToday(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.gotoToday(sender)
	}

	@IBAction func gotoAllUnread(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.gotoAllUnread(sender)
	}

	@IBAction func gotoStarred(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.gotoStarred(sender)
	}

	@IBAction func showCustomAboutPanel(_ sender: Any?) {
		if aboutWindowController == nil {
			aboutWindowController = AboutWindowController(windowNibName: "AboutWindowController")
			aboutWindowController?.window?.center()
		}
		aboutWindowController?.showWindow(nil)
		aboutWindowController?.window?.makeKeyAndOrderFront(nil)
	}

	@IBAction func toggleColumnLayout(_ sender: Any?) {
		AppDefaults.shared.useColumnLayout.toggle()
	}
}

// MARK: - Debug Menu
extension AppDelegate {

	@IBAction func debugSearch(_ sender: Any?) {
		AccountManager.shared.defaultAccount.debugRunSearch()
	}

	@IBAction func debugDropConditionalGetInfo(_ sender: Any?) {
#if DEBUG
		for account in AccountManager.shared.activeAccounts {
			account.debugDropConditionalGetInfo()
		}
#endif
	}

	@IBAction func forceCrash(_ sender: Any?) {
		fatalError("This is a deliberate crash.")
	}

	@IBAction func openApplicationSupportFolder(_ sender: Any?) {
		guard let appSupport = Platform.dataSubfolder(forApplication: nil, folderName: "") else {
			assertionFailure("Expected non-nil app support folder path")
			return
		}

		NSWorkspace.shared.open(URL(fileURLWithPath: appSupport))
	}

	@IBAction func toggleWebInspectorEnabled(_ sender: Any?) {
		let newValue = !AppDefaults.shared.webInspectorEnabled
		AppDefaults.shared.webInspectorEnabled = newValue

			// An attached inspector can display incorrectly on certain setups (like mine); default to displaying in a separate window,
			// and reset the default to a separate window when the preference is toggled off and on again in case the inspector is
			// accidentally reattached.
		AppDefaults.shared.webInspectorStartsAttached = false
			NotificationCenter.default.post(name: .WebInspectorEnabledDidChange, object: newValue)
	}

	@IBAction func openImageCacheFolder(_ sender: Any?) {
		NSWorkspace.shared.open(AppConfig.cacheFolder)
	}

}

@MainActor internal extension AppDelegate {

	func fireOldTimers() {
		// It’s possible the sync timer was set to go off in the past.
		ArticleStatusSyncTimer.shared.fireOldTimer()
	}

	func objectsForInspector() -> [Any]? {
		guard let window = NSApplication.shared.mainWindow, let windowController = window.windowController as? MainWindowController else {
			return nil
		}
		return windowController.selectedObjectsInSidebar()
	}

	func saveState() {
		guard !Platform.isRunningUnitTests else {
			return
		}

		mainWindowController?.saveStateToUserDefaults()

		inspectorWindowController?.saveState()
		activityWindowController?.saveState()
		activityLogWindowController?.saveState()
		errorLogWindowController?.saveState()
	}

	@MainActor func updateColumnLayoutMenuItem() {
		useColumnLayoutMenuItem.state = AppDefaults.shared.useColumnLayout ? .on : .off
	}

	func importTheme(url: URL) {
		guard let window = mainWindowController?.window else { return }

		do {
			let theme = try ArticleTheme(url: url, isAppTheme: false)
			let alert = NSAlert()
			alert.alertStyle = .informational

			let localizedMessageText = NSLocalizedString("Install theme “%@” by %@?", comment: "Theme message text")
			alert.messageText = NSString.localizedStringWithFormat(localizedMessageText as NSString, theme.name, theme.creatorName) as String

			var attributes = [NSAttributedString.Key: Any]()
			attributes[.font] = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
			attributes[.foregroundColor] = NSColor.textColor

			let titleParagraphStyle = NSMutableParagraphStyle()
			titleParagraphStyle.alignment = .center
			attributes[.paragraphStyle] = titleParagraphStyle

			let websiteText = NSMutableAttributedString()
			websiteText.append(NSAttributedString(string: NSLocalizedString("Author‘s website:", comment: "Author's Website"), attributes: attributes))

			websiteText.append(NSAttributedString(string: "\n"))

			if let homePageURL = URL(string: theme.creatorHomePage), homePageURL.isHTTPOrHTTPSURL() {
				attributes[.link] = theme.creatorHomePage
			}
			websiteText.append(NSAttributedString(string: theme.creatorHomePage, attributes: attributes))

			let textViewWidth: CGFloat
			textViewWidth = 200

			let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: textViewWidth, height: 15))
			textView.isEditable = false
			textView.drawsBackground = false
			textView.textStorage?.setAttributedString(websiteText)
			alert.accessoryView = textView

			alert.addButton(withTitle: NSLocalizedString("Install Theme", comment: "Install Theme"))
			alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

			func importTheme() {
				do {
					try ArticleThemesManager.shared.importTheme(filename: url.path)
					confirmImportSuccess(themeName: theme.name)
				} catch {
					NSApplication.shared.presentError(error)
				}
			}

			alert.beginSheetModal(for: window) { result in
				if result == NSApplication.ModalResponse.alertFirstButtonReturn {

					if ArticleThemesManager.shared.themeExists(filename: url.path) {
						let alert = NSAlert()
						alert.alertStyle = .warning

						let localizedMessageText = NSLocalizedString("The theme “%@” already exists. Overwrite it?", comment: "Overwrite theme")
						alert.messageText = NSString.localizedStringWithFormat(localizedMessageText as NSString, theme.name) as String

						alert.addButton(withTitle: NSLocalizedString("Overwrite", comment: "Overwrite"))
						alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

						alert.beginSheetModal(for: window) { result in
							if result == NSApplication.ModalResponse.alertFirstButtonReturn {
								importTheme()
							}
						}
					} else {
						importTheme()
					}
				}
			}
		} catch {
			NotificationCenter.default.post(name: .didFailToImportThemeWithError, object: nil, userInfo: ["error": error, "path": url.path])
		}
	}

	func confirmImportSuccess(themeName: String) {
		guard let window = mainWindowController?.window else { return }

		let alert = NSAlert()
		alert.alertStyle = .informational
		alert.messageText = NSLocalizedString("Theme installed", comment: "Theme installed")

		let localizedInformativeText = NSLocalizedString("The theme “%@” has been installed.", comment: "Theme installed")
		alert.informativeText = NSString.localizedStringWithFormat(localizedInformativeText as NSString, themeName) as String

		alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))

		alert.beginSheetModal(for: window)
	}

	@objc func themeImportError(_ note: Notification) {
		guard let userInfo = note.userInfo,
			  let error = userInfo["error"] as? Error else {
				  return
			  }
		themeImportPath = userInfo["path"] as? String
		let informativeText = ArticleThemesManager.importErrorMessage(for: error)

		DispatchQueue.main.async {
			let alert = NSAlert()
			alert.alertStyle = .warning
			alert.messageText = NSLocalizedString("Theme Error", comment: "Theme download error")
			alert.informativeText = informativeText
			alert.addButton(withTitle: NSLocalizedString("Open Theme Folder", comment: "Open Theme Folder"))
			alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))

			let button = alert.buttons.first
			button?.target = self
			button?.action = #selector(self.openThemesFolder(_:))
			alert.buttons[0].keyEquivalent = "\033"
			alert.buttons[1].keyEquivalent = "\r"
			alert.runModal()
		}
	}

	@objc func openThemesFolder(_ sender: Any) {
		if themeImportPath == nil {
			let url = URL(fileURLWithPath: ArticleThemesManager.shared.folderPath)
			NSWorkspace.shared.open(url)
		} else {
			let url = URL(fileURLWithPath: themeImportPath!)
			NSWorkspace.shared.open(url.deletingLastPathComponent())
		}
	}

}

extension AppDelegate: NSWindowRestoration {

	@objc static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void) {
		var mainWindow: NSWindow?
		if identifier.rawValue == WindowRestorationIdentifiers.mainWindow {
			mainWindow = appDelegate.createAndShowMainWindow().window
		}
		completionHandler(mainWindow, nil)
	}
}
