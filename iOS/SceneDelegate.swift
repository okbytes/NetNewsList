//
//  AppDelegate.swift
//  NetNewsWire
//
//  Created by Maurice Parker on 6/28/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import UserNotifications
import Account

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

	var window: UIWindow?
	var coordinator: SceneCoordinator!

	// UIWindowScene delegate

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {

		window!.tintColor = Assets.Colors.primaryAccent

		let rootViewController = window!.rootViewController as! RootSplitViewController
		rootViewController.presentsWithGesture = true
		rootViewController.showsSecondaryOnlyButton = true
		rootViewController.preferredDisplayMode = UISplitViewController.DisplayMode(rawValue: AppDefaults.shared.splitViewPreferredDisplayMode) ?? .oneBesideSecondary

		// On first run on iPad, show all three columns so the sidebar is visible
		if AppDefaults.shared.isFirstRun && UIDevice.current.userInterfaceIdiom == .pad {
			rootViewController.preferredDisplayMode = .twoBesideSecondary
		}

		coordinator = SceneCoordinator(rootSplitViewController: rootViewController)
		rootViewController.coordinator = coordinator
		rootViewController.delegate = coordinator

		// An external action (notification tap, URL, shortcut, or user activity)
		// dictates navigation. Also doing selection restoration — previously selected feed
		// and article — at the same time would start two competing navigations.
		// <https://github.com/Ranchero-Software/NetNewsWire/issues/4638>
		// Restore the window state, but skip restoring the selection.
		let hasPendingExternalAction = connectionOptions.notificationResponse != nil ||
			connectionOptions.urlContexts.first?.url != nil ||
			connectionOptions.shortcutItem != nil ||
			!connectionOptions.userActivities.isEmpty

		coordinator.restoreWindowState(restoreSelection: !hasPendingExternalAction)

		if connectionOptions.urlContexts.first?.url != nil {
			self.scene(scene, openURLContexts: connectionOptions.urlContexts)
			return
		}

		if let shortcutItem = connectionOptions.shortcutItem {
			handleShortcutItem(shortcutItem)
			return
		}

		if let notificationResponse = connectionOptions.notificationResponse {
			coordinator.handle(notificationResponse)
			return
		}

		// Handle activities from external sources (Handoff, Spotlight, Siri Shortcuts).
		// Skip handling session.stateRestorationActivity since UserDefaults now handles state restoration.
		if let userActivity = connectionOptions.userActivities.first {
			coordinator.handle(userActivity)
		}
	}

	func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
		appDelegate.resumeIfNecessary()
		handleShortcutItem(shortcutItem)
		completionHandler(true)
	}

	func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
		appDelegate.resumeIfNecessary()
		coordinator.handle(userActivity)
	}

	func sceneDidEnterBackground(_ scene: UIScene) {
		appDelegate.prepareAccountsForBackground()
	}

	func sceneWillEnterForeground(_ scene: UIScene) {
		appDelegate.resumeIfNecessary()
		appDelegate.prepareAccountsForForeground()
		coordinator.resetFocus()
	}

	func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
		return coordinator.stateRestorationActivity
	}

	// API

	func handle(_ response: UNNotificationResponse) {
		appDelegate.resumeIfNecessary()
		coordinator.handle(response)
	}

	func suspend() {
		coordinator.suspend()
	}

	// Handle Opening of URLs

	func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
		guard let context = urlContexts.first else { return }

		DispatchQueue.main.async {

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				self.coordinator.dismissIfLaunchingFromExternalAction()
			}

			let urlString = context.url.absoluteString

			// Show the Queue, or an article in it
			if urlString.contains(WidgetDeepLink.queue.url.absoluteString) {
				guard let comps = URLComponents(string: urlString ) else { return  }
				let id = comps.queryItems?.first(where: { $0.name == "id" })?.value
				if id != nil {
					if AccountManager.shared.isSuspended {
						AccountManager.shared.resumeAll()
					}
					self.coordinator.selectQueue {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
							self.coordinator.selectArticleInCurrentFeed(id!)
						}
					}
				} else {
					self.coordinator.selectQueue()
				}
				return
			}

			// Save a page: netnewslist://add?url={url}&title={title}
			if let request = AddArticleURLScheme.request(from: context.url) {
				Task { @MainActor in
					do {
						try await ExtractionCoordinator.shared.saveArticle(url: request.url, title: request.title)
					} catch {
						self.coordinator.showAddArticle(initialURL: request.url)
					}
				}
				return
			}
		}
	}
}

private extension SceneDelegate {

	func handleShortcutItem(_ shortcutItem: UIApplicationShortcutItem) {
		switch shortcutItem.type {
		case "NetNewsList.ShowQueue":
			coordinator.selectQueue()
		case "NetNewsList.ShowAdd":
			coordinator.showAddArticle()
		default:
			break
		}
	}
}
