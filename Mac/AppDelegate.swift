//
//  AppDelegate.swift
//  NetNewsWire
//
//  Created by Brent Simmons on 7/11/15.
//  Copyright © 2015 Ranchero Software, LLC. All rights reserved.
//

import AppKit
import SwiftUI
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
import CloudKitSync

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
	private var aboutWindowController: AboutWindowController?
	private var addArticleSheet: NSWindow?
	private var keyboardShortcutsWindowController: WebViewWindowController?
	private var activityWindowController: CurrentActivityWindowController?
	private var activityLogWindowController: ActivityLogWindowController?
	private var errorLogWindowController: ErrorLogWindowController?
	private var xSignInWindowController: XSignInWindowController?
	private var iCloudSignInWindowController: ICloudSignInWindowController?
	private var iCloudRenewalTimer: Timer?
	private let appMovementMonitor: RSAppMovementMonitor

	@MainActor override init() {
		NSMenuItem.rs_disableIcons()
		NSWindow.allowsAutomaticWindowTabbing = false
		self.appMovementMonitor = RSAppMovementMonitor()
		super.init()

		appDelegate = self
		AccountManager.shared.start()

		NotificationCenter.default.addObserver(self, selector: #selector(unreadCountDidChange(_:)), name: .UnreadCountDidChange, object: AccountManager.shared)
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWakeNotification(_:)), name: NSWorkspace.didWakeNotification, object: nil)
	}

	// MARK: - API

	func showAddArticleSheetOnWindow(_ window: NSWindow, urlString: String?, title: String?) {
		let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
		let view = AddArticleView(initialURL: urlString, initialTitle: title) { [weak self, weak window, weak sheet] in
			if let window, let sheet {
				window.endSheet(sheet)
			}
			self?.addArticleSheet = nil
		}
		sheet.contentViewController = NSHostingController(rootView: view)
		addArticleSheet = sheet
		window.beginSheet(sheet)
	}

	// MARK: - NSApplicationDelegate

	func applicationWillFinishLaunching(_ notification: Notification) {
		FaviconGenerator.templateImage = Assets.Images.faviconTemplate

		installAppleEventHandlers()
		SavePageService.shared.register()

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

		if mainWindowController == nil {
			let mainWindowController = createAndShowMainWindow()
			mainWindowController.restoreStateFromUserDefaults()
		}

		if isFirstRun {
			mainWindowController?.window?.center()
		}

		NotificationCenter.default.addObserver(self, selector: #selector(feedSettingDidChange(_:)), name: .feedSettingDidChange, object: nil)

		DispatchQueue.main.async {
			self.unreadCount = AccountManager.shared.unreadCount
		}

		if !Platform.isRunningUnitTests {
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

		NetworkMonitor.shared.start()
		MemoryPressureMonitor.shared.start()

		if !Platform.isRunningUnitTests {
			ExtractionCoordinator.shared.start()
			ArticleAssetCoordinator.shared.start()
			SavedArticleRequestProcessor.shared.start()
			ReadingListBackups.shared.start()
			// A copy that reaches iCloud over the web signs in by itself; ask at once when it hasn’t.
			if CloudKitWebSync.isEnabled {
				NotificationCenter.default.addObserver(self, selector: #selector(iCloudWebSignInDidChange(_:)), name: .CloudKitWebSignInDidChange, object: nil)
				if !CloudKitWebSync.shared.isSignedIn {
					if CloudKitWebSync.shared.hasSignedInBefore && !CloudKitWebSync.shared.needsAPIToken {
						// The sign-in is gone (iCloud ended it while the app was closed, or the keychain
						// lost it); Apple’s page may still know this Mac and sign in by itself.
						renewICloudSignIn(force: true)
					} else {
						signInOrOutOfICloud(self)
					}
				} else if CloudKitWebSync.shared.needsAPIToken {
					// An update without the built-in token (a release): the sign-in holds, only the token is missing.
					_ = ICloudSignInWindowController.askForAPIToken()
				}
				// A sign-in made with Keep me signed in lasts two weeks: renew it before then.
				iCloudRenewalTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
					Task { @MainActor in
						self?.renewICloudSignInIfDue()
					}
				}
			}
		}

		ArticleStatusSyncTimer.shared.start()

		// Silent CloudKit pushes don’t need notification permission.
		NSApplication.shared.registerForRemoteNotifications()

		// Badging the Dock icon needs this permission — it’s not just for alerts.
		UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert]) { _, _ in }

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

	/// Over the web, every answer carries the next sign-in token, so a request cut off by quitting
	/// (an update, a restart) leaves the app with a spent one and the next launch signed out.
	/// Send what’s pending and let the request out finish before the app goes.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard CloudKitWebSync.isEnabled, !isShutDownSyncDone, let service = CloudKitWebSync.shared.service else {
			return .terminateNow
		}
		shuttingDown = true
		Task { @MainActor in
			await withTaskGroup(of: Void.self) { group in
				group.addTask {
					await AccountManager.shared.sendArticleStatusAll()
				}
				group.addTask {
					try? await Task.sleep(for: .seconds(8))
				}
				await group.next()
				group.cancelAll()
			}
			await service.waitUntilIdle(timeout: 4)
			isShutDownSyncDone = true
			NSApp.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}

	func applicationWillTerminate(_ notification: Notification) {
		shuttingDown = true
		saveState()

		AccountManager.shared.saveAllIfNeeded()

		if !isShutDownSyncDone {
			Task { @MainActor in
				await AccountManager.shared.sendArticleStatusAll()
				isShutDownSyncDone = true
			}
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

	@objc func didWakeNotification(_ note: Notification) {
		Task { @MainActor in
			ArticleStatusSyncTimer.shared.fireOldTimer()
			renewICloudSignInIfDue()
			await XAccount.shared.updateSignInState()
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

		if item.action == #selector(showAddArticleWindow(_:)) {
			return !isDisplayingSheet && !AccountManager.shared.activeAccounts.isEmpty
		}

		if item.action == #selector(toggleWebInspectorEnabled(_:)) {
			(item as! NSMenuItem).state = AppDefaults.shared.webInspectorEnabled ? .on : .off
		}

		// A main window checks the list it shows. Without one, neither is checked.
		if item.action == #selector(gotoQueue(_:)) || item.action == #selector(gotoArchive(_:)), let menuItem = item as? NSMenuItem {
			menuItem.state = .off
		}

		// Only a copy that reaches iCloud over the web signs in by itself.
		if item.action == #selector(signInOrOutOfICloud(_:)), let menuItem = item as? NSMenuItem {
			menuItem.isHidden = !CloudKitWebSync.isEnabled
			menuItem.title = CloudKitWebSync.isEnabled && CloudKitWebSync.shared.isSignedIn ? NSLocalizedString("Sign Out of iCloud…", comment: "Menu item") : NSLocalizedString("Sign In to iCloud…", comment: "Menu item")
			return CloudKitWebSync.isEnabled
		}

		if item.action == #selector(signInOrOutOfX(_:)), let menuItem = item as? NSMenuItem {
			menuItem.title = XAccount.shared.isSignedIn ? NSLocalizedString("Sign Out of X…", comment: "Menu item") : NSLocalizedString("Sign In to X…", comment: "Menu item")
			// Look again, in case the cookie store’s answer at launch was wrong; the title follows.
			Task { @MainActor in
				await XAccount.shared.updateSignInState()
			}
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
			if wrappedResponse.value.notification.request.identifier == Self.iCloudSignInEndedNotificationID {
				// Never the sign-out alert: an old notification can be clicked after signing in again.
				if CloudKitWebSync.isEnabled && !CloudKitWebSync.shared.isSignedIn {
					showICloudSignInWindow()
				} else {
					showMainWindow(nil)
				}
			} else {
				mainWindowController?.handle(wrappedResponse.value)
			}
			wrappedCompletionHandler.value()
		}
    }

	private static let iCloudSignInEndedNotificationID = "iCloudWebSignInEnded"

	/// iCloud ended the web sign-in (it lasts at most two weeks, or web access was turned off).
	/// Apple’s page may sign in again by itself; when it can’t, syncing has stopped, so say so
	/// rather than let the Mac quietly fall behind.
	@objc func iCloudWebSignInDidChange(_ note: Notification) {
		guard !CloudKitWebSync.shared.isSignedIn else {
			UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.iCloudSignInEndedNotificationID])
			return
		}
		guard (note.userInfo?[CloudKitWebService.signInEndedByICloudKey] as? Bool) == true else {
			return
		}
		renewICloudSignIn(force: true)
	}

	/// Renews the sign-in before Apple ends it, when it’s old enough.
	func renewICloudSignInIfDue() {
		guard ICloudSignInRenewer.shared.isRenewalDue else {
			return
		}
		renewICloudSignIn(force: false)
	}

	/// Signs in again through Apple’s page out of sight; when the page needs the user, shows a
	/// notification that opens the sign-in (the window itself, when the sign-in is already gone
	/// and the app was just opened).
	func renewICloudSignIn(force: Bool) {
		Task { @MainActor in
			let wasSignedIn = CloudKitWebSync.shared.isSignedIn
			switch await ICloudSignInRenewer.shared.renew(force: force) {
			case .renewed, .skipped:
				return
			case .differentAccount(let signIn):
				showICloudSignInWindow()
				iCloudSignInWindowController?.showAskingAboutDifferentAccount(signIn)
			case .needsUser:
				guard !CloudKitWebSync.shared.isSignedIn else {
					return
				}
				if !wasSignedIn && NSApp.isActive && iCloudSignInWindowController?.window?.isVisible != true {
					showICloudSignInWindow()
				} else {
					postICloudSignInEndedNotification()
				}
			}
		}
	}

	func postICloudSignInEndedNotification() {
		let content = UNMutableNotificationContent()
		content.title = NSLocalizedString("Sign in to iCloud again", comment: "Notification title")
		content.body = NSLocalizedString("iCloud ended this Mac’s sign-in, so your reading list isn’t syncing. Click to sign in.", comment: "Notification body")
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.iCloudSignInEndedNotificationID, content: content, trigger: nil))
	}

	// MARK: Add Article
	@MainActor func addArticle(_ urlString: String?, title: String? = nil) {
		let windowController = createAndShowMainWindowIfNecessary()
		guard !windowController.isDisplayingSheet, let window = windowController.window else {
			return
		}
		showAddArticleSheetOnWindow(window, urlString: urlString, title: title)
	}

	// MARK: - Dock Badge

	/// The number of articles in the Queue, or nothing when it is empty.
	@objc func updateDockBadge() {
		Task { @MainActor in
			NSApplication.shared.dockTile.badgeLabel = unreadCount > 0 ? unreadCount.formatted() : ""
		}
	}

	// MARK: - Actions

	@IBAction func newMainWindow(_ sender: Any?) {
		createAndShowMainWindow()
	}

	@IBAction func showMainWindow(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.window?.makeKey()
	}

	/// Signed out, shows X's sign-in page; signed in, offers to sign out. X shows some posts only to signed-in people.
	@IBAction func signInOrOutOfX(_ sender: Any?) {
		guard XAccount.shared.isSignedIn else {
			if xSignInWindowController == nil {
				xSignInWindowController = XSignInWindowController()
			}
			xSignInWindowController?.showWindow(self)
			return
		}
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("Sign Out of X?", comment: "Sign out of X alert title")
		alert.informativeText = NSLocalizedString("Posts that X shows only to signed-in people won’t be saved from this Mac until you sign in again.", comment: "Sign out of X alert message")
		alert.addButton(withTitle: NSLocalizedString("Sign Out", comment: "Sign Out button"))
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		xSignInWindowController = nil
		Task {
			await XAccount.shared.signOut()
		}
	}

	@IBAction func signInOrOutOfICloud(_ sender: Any?) {
		guard CloudKitWebSync.isEnabled else {
			return
		}
		guard CloudKitWebSync.shared.isSignedIn else {
			showICloudSignInWindow()
			return
		}
		let alert = NSAlert()
		alert.messageText = NSLocalizedString("Sign Out of iCloud?", comment: "Sign out of iCloud alert title")
		alert.informativeText = NSLocalizedString("The articles on this Mac stay here, but nothing syncs with your other devices until you sign in again.", comment: "Sign out of iCloud alert message")
		alert.addButton(withTitle: NSLocalizedString("Sign Out", comment: "Sign Out button"))
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		iCloudSignInWindowController = nil
		Task {
			await CloudKitWebSync.shared.signOut()
		}
	}

	private func showICloudSignInWindow() {
		if iCloudSignInWindowController == nil {
			iCloudSignInWindowController = ICloudSignInWindowController()
		}
		iCloudSignInWindowController?.showWindow(self)
	}

	@IBAction func resetiCloudSync(_ sender: Any?) {
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = NSLocalizedString("Reset iCloud Sync?", comment: "Reset iCloud Sync alert title")
		alert.informativeText = NSLocalizedString("NetNewsList will download everything from iCloud again, then upload any article on this Mac that iCloud doesn’t have. Nothing is deleted.", comment: "Reset iCloud Sync alert message")
		alert.addButton(withTitle: NSLocalizedString("Reset", comment: "Reset button"))
		alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		Task {
			do {
				try await AccountManager.shared.defaultAccount.resetiCloudSync()
			} catch {
				mainWindowController?.presentError(error)
			}
		}
	}

	@IBAction func showBackupsInFinder(_ sender: Any?) {
		ReadingListBackups.shared.showInFinder()
	}

	@IBAction func showErrorLog(_ sender: Any?) {
		if errorLogWindowController == nil {
			errorLogWindowController = ErrorLogWindowController()
		}
		errorLogWindowController!.showWindow(self)
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

	@IBAction func showAddArticleWindow(_ sender: Any?) {
		addArticle(NSPasteboard.urlString(from: NSPasteboard.general)?.normalizedURL)
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

	@IBAction func gotoQueue(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.gotoQueue(sender)
	}

	@IBAction func gotoArchive(_ sender: Any?) {
		let windowController = createAndShowMainWindowIfNecessary()
		windowController.gotoArchive(sender)
	}

	@IBAction func showCustomAboutPanel(_ sender: Any?) {
		if aboutWindowController == nil {
			aboutWindowController = AboutWindowController(windowNibName: "AboutWindowController")
			aboutWindowController?.window?.center()
		}
		aboutWindowController?.showWindow(nil)
		aboutWindowController?.window?.makeKeyAndOrderFront(nil)
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

	func saveState() {
		guard !Platform.isRunningUnitTests else {
			return
		}

		mainWindowController?.saveStateToUserDefaults()

		activityWindowController?.saveState()
		activityLogWindowController?.saveState()
		errorLogWindowController?.saveState()
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
