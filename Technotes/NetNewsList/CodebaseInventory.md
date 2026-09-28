# NetNewsList codebase inventory

This is the file-by-file companion to `Plan.md`: for every surveyed path in the NetNewsWire fork it says whether the file stays, changes or goes as the fork becomes NetNewsList, the CloudKit-only personal reading list. Verdicts follow the decisions (D1-D7), the PR roadmap (PR1-PR12) and the deletion inventory of `Plan.md`; where the readers who produced the raw survey disagreed with the plan, the plan wins. Line counts are Swift lines for directories and file lines for files, as measured in the survey. Legend: **keep** = unchanged or trivial edits; **adapt** = kept with the described changes; **delete** = removed; **delete (PRn)** / **adapt (PRn)** = the plan names the PR that does it (a file touched by several PRs carries the first one in the tag and the rest in the sentence); **decide** = the plan itself leaves it open (only the Today smart feed and the Today widget: "delete unless Today is kept as Saved Today"). Account-zone files are **adapt**, not delete, because deleting the Account zone is an optional follow-up; the `-DEBUG` bundle and group suffixes are kept. Within each group entries are sorted delete, adapt, keep, decide.

## .github

- **delete** `.github/CODEOWNERS` — Upstream code-owner rule (`* @brentsimmons`) with no meaning in the fork.
- **adapt (PR1)** `.github/workflows/ci.yml` — SwiftLint plus macOS and iOS simulator jobs on Xcode 26.3 that run `updateSecrets.sh` (:40, :85) and force `-DSKIP_APP_GROUP_ACCESS` on iOS (:106); trimmed to lint plus both builds in PR1, loses the Secrets steps in PR5 and is restored to lint, build and test on both platforms in PR12.
- **keep** `.github/ios-ci-no-signing.xcconfig` (5 lines) — Disables code signing for the iOS CI job.
- **keep** `.github/macos-ci-no-signing.xcconfig` (6 lines) — Disables code signing for the macOS CI job and excludes `*.applescript`, an exclusion that becomes moot after PR3 but is harmless.

## .gitignore

- **adapt (PR5)** `.gitignore` — Ignores the generated `SecretKey.swift` (:90-91), `Package.resolved` and `.claude/`; the SecretKey lines go with Secrets.

## .swiftlint.yml

- **adapt (PR2)** `.swiftlint.yml` — Strict lint configuration run by CI; drop the excludes for the deleted Feedly and Account test folders (PR2) and the `SecretKey.swift` exclude (:42, PR5).

## AppStore

- **delete** `AppStore/NetNewsWire7` — Upstream App Store copy and screenshots.

## Appcasts

- **delete (PR1)** `Appcasts` — Sparkle appcast XML files; go with Sparkle.

## AppleScript

- **delete (PR3)** `AppleScript` — Sample AppleScripts; scripting support is removed.

## Mac/About

- **adapt (PR12)** `Mac/About` (294 lines) — Custom About window with links; re-credited and repointed with the Help items.

## Mac/AccountStats

- **delete (PR5)** `Mac/AccountStats` (306 lines) — Per-account feed/folder/article/status counts window (controller, xib and xcstrings, all files); one of the AccountStats windows removed under C6.

## Mac/ActivityLog

- **keep** `Mac/ActivityLog/ActivityLogWindowController.swift` (221 lines) — Activity log viewer; generic and still useful for sync and extraction activity.

## Mac/AppDefaults.swift

- **adapt (PR3)** `Mac/AppDefaults.swift` (439 lines) — UserDefaults keys for the Mac app; loses `subscribeToFeedsInDefaultBrowser` (:36, :126-131, PR3), `isDeveloperBuild` (PR4), `refreshInterval` (:38, :303-312, :327-329, :348, PR5) and the add-feed/folder, OPML, `timelineGroupByFeed` and `feedDoubleClickMarkAsRead` keys (PR9).

## Mac/AppDelegate.swift

- **adapt (PR1)** `Mac/AppDelegate.swift` (1077 lines) — App lifecycle, menu actions, push registration (:261) and remote-notification fan-out (:332-336) stay; Sparkle and the crash reporter go in PR1, scripting, Dinosaurs, OPML/NNW3, `addAppNews`, `DefaultFeedsImporter` and `UserNotificationManager` in PR3, the `SKIP_APP_GROUP_ACCESS` guards (:252-255) and `appName` (:26) in PR4, `refreshTimer` (:39-40, :257, :267-276, :395-413) in PR5, and the Help actions bound in MainMenu.xib (:697-733) are repointed rather than deleted in PR12.

## Mac/Base.lproj

- **delete (PR6)** `Mac/Base.lproj/AddFeedFromListSheet.xib` — Add-from-curated-list sheet nib; goes with Add Feed.
- **delete (PR6)** `Mac/Base.lproj/AddFeedSheet.xib` — Add Feed sheet nib; replaced by the SwiftUI Add Article sheet in an `NSHostingController`.
- **delete (PR9)** `Mac/Base.lproj/AddFolderSheet.xib` (118 lines) — Add Folder sheet nib; goes with `Mac/MainWindow/AddFolder`.
- **delete (PR9)** `Mac/Base.lproj/RenameSheet.xib` (95 lines) — Rename sheet nib; goes with `RenameWindowController`.

## Mac/Browser.swift

- **keep** `Mac/Browser.swift` (80 lines) — Opens a URL in the default or chosen browser, foreground or background.

## Mac/CloudKitStats

- **delete (PR5)** `Mac/CloudKitStats` (1189 lines) — iCloud Stats window with Scan and Clean Up panes (10 files) built on the read/unread/stale content-retention model that C6 removes; deleted with `CloudKitStats.swift` and `CloudKitStatsViewModel.swift`.

## Mac/CrashReporter

- **delete (PR1)** `Mac/CrashReporter` (138 lines) — PLCrashReporter check and upload to services.netnewswire.com; removed with the plcrashreporter package.

## Mac/CurrentActivity

- **adapt** `Mac/CurrentActivity/CurrentActivityWindowController.swift` (150 lines) — Live table of running ActivityLog activities, today used for feed refresh; keep for sync and extraction activity or delete with the refresh UI (open question 10).

## Mac/Dinosaurs

- **delete (PR3)** `Mac/Dinosaurs/DinosaursWindowController.swift` (417 lines) — Window listing feeds that have stopped updating; goes with its xib and xcstrings.

## Mac/ErrorHandler.swift

- **keep** `Mac/ErrorHandler.swift` (39 lines) — `presentError` helper.

## Mac/ErrorLog

- **keep** `Mac/ErrorLog/ErrorLogWindowController.swift` (195 lines) — Error log viewer.

## Mac/Inspector

- **delete (PR9)** `Mac/Inspector` (614 lines) — Floating Info window with Feed, Folder, built-in smart feed and Nothing inspectors plus nibs and xcstrings; the Mac's last reader of `Feed.readerViewAlwaysEnabled`.

## Mac/MainMenu

- **adapt (PR1)** `Mac/MainMenu/Base.lproj/MainMenu.xib` — Main menu nib; loses Check for Updates and the debug crash items (PR1), Import/Export Subscriptions, NNW 3 import, Dinosaurs and Add NetNewsWire News Feed (PR3), New Folder, Hide Read Feeds, Sort by Feed and Info with Mark All as Read becoming Archive All (PR9), while the Help items stay bound to their existing selectors until PR12 repoints them.

## Mac/MainWindow

- **delete (PR6)** `Mac/MainWindow/AddFeed` (408 lines) — Add Feed sheet (`AddFeedController`, `AddFeedWindowController`, `FolderTreeMenu`, all files); replaced by the Add Article sheet in `Mac/MainWindow/AddArticle/`, which takes over the pasteboard prefill (:39, :97-102).
- **delete (PR9)** `Mac/MainWindow/AddFolder/AddFolderWindowController.swift` (122 lines) — Add Folder sheet; no folders.
- **delete (PR3)** `Mac/MainWindow/NNW3` (302 lines) — NetNewsWire 3 Subscriptions.plist importer.
- **delete (PR3)** `Mac/MainWindow/OPML` (229 lines) — Import and Export OPML sheets with account picker.
- **delete (PR9)** `Mac/MainWindow/Sidebar/PasteboardFeed.swift` (222 lines) — Feed pasteboard representation for drag and drop; its `.URL`/`.string` parsing (:91-103) moves into the ~40-line URL-drop acceptor in `SidebarOutlineDataSource` before the file goes.
- **delete (PR9)** `Mac/MainWindow/Sidebar/PasteboardFolder.swift` (135 lines) — Folder pasteboard representation.
- **delete (PR9)** `Mac/MainWindow/Sidebar/Renaming/RenameWindowController.swift` (78 lines) — Rename feed/folder sheet; fixed lists are not renamed.
- **delete (PR9)** `Mac/MainWindow/Sidebar/SidebarDeleteItemsAlert.swift` (42 lines) — Delete feed/folder confirmation.
- **delete (PR9)** `Mac/MainWindow/Sidebar/SidebarViewController+ContextualMenus.swift` (352 lines) — Feed, folder and smart-feed context menus, including two `readerViewAlwaysEnabled` reads (:141, :239) that PR7 removes first; an Archive All item for a list can move into `SidebarViewController`.
- **adapt (PR7)** `Mac/MainWindow/ArticleExtractorButton.swift` (90 lines) — Reader View toolbar button with spinner; becomes the Show Original toggle.
- **adapt (PR9)** `Mac/MainWindow/Detail/DetailIconSchemeHandler.swift` (46 lines) — `nnwImageIcon` scheme handler rendering `Article.iconImage()` to a 48x48 PNG; the icon source becomes `SiteFaviconCache` (PR9) and the handler is the template for `ArticleAssetSchemeHandler` (PR11).
- **adapt (PR7)** `Mac/MainWindow/Detail/DetailViewController.swift` (162 lines) — Owns `DetailState` and swaps the regular and search web view controllers; drops the `.extracted` case (:20).
- **adapt (PR7)** `Mac/MainWindow/Detail/DetailWebViewController.swift` (463 lines) — Renders `DetailState` through `ArticleRenderer` into `page.html` with navigation policy, scroll restore and crash recovery; drops the `.extracted` handling (:31, :46-55, :90-97, :382-385), passes `allowsContentJavaScript = false` for stored content (:243) and keeps the `.FaviconDidBecomeAvailable` reload (:121).
- **adapt (PR7)** `Mac/MainWindow/Detail/DetailWindowState.swift` (41 lines) — Secure-coded detail restoration state; drops `isShowingExtractedArticle` (:39).
- **adapt (PR4)** `Mac/MainWindow/MainWindowController.swift` (1802 lines) — Window, toolbar and three-pane coordination; loses the developer-build gate (:1480-1483, PR4), the Refresh/New Feed/New Folder toolbar items, `CombinedRefreshProgress` observer (:111) and feed-name title (PR5/PR9) and all extractor plumbing (~:474, :499, :715-717, :811-820, :1361, :1693-1698, PR7).
- **adapt (PR9)** `Mac/MainWindow/Sidebar/SidebarOutlineDataSource.swift` (709 lines) — Outline data source with ~650 lines of feed/folder drag-and-drop validation; shrinks to the three required methods plus ~40 lines accepting URL drops taken over from `PasteboardFeed` (`acceptSingleNonLocalFeedDrop`, :511-526, is the only external-URL drop path today).
- **adapt (PR5)** `Mac/MainWindow/Sidebar/SidebarStatusBarView.swift` (135 lines) — Refresh progress bar at the bottom of the sidebar; re-sourced from `syncProgress` through `CombinedRefreshProgress` so Sync Now shows progress, or deleted with the refresher (open question 10).
- **adapt (PR9)** `Mac/MainWindow/Sidebar/SidebarViewController.swift` (959 lines) — Outline controller owning `TreeController`, selection, next-unread and state restore; loses drag registration (:92), delete (:292), rename, feed icon prefetch, `userDidAddFeed`, `feedSettingDidChange`, folder filter exceptions and `findAccountNode`.
- **adapt (PR9)** `Mac/MainWindow/Timeline/TimelineColumn.swift` (122 lines) — Column enum (unread, starred, feed, title, date); `.feed` becomes `.site`.
- **adapt (PR9)** `Mac/MainWindow/Timeline/TimelineViewController+ColumnLayout.swift` (178 lines) — Column-layout headers; the Feed column becomes Site.
- **adapt (PR7)** `Mac/MainWindow/Timeline/TimelineViewController+ContextualMenus.swift` (302 lines) — Article context menu; loses `selectFeedInSidebar` (:67, :252) and `markAllInFeedAsRead` (:74, :258), gains Retry and Retry with Live Page (PR7) and Delete (PR9).
- **adapt (PR9)** `Mac/MainWindow/Timeline/TimelineViewController.swift` (1411 lines) — Article list with fetch, sort, undoable marking, next-unread and restoration; the `article.feed` reads (:688, :721, :1012) become site lookups, the feed-name column shows the host, and the `userInfo[feeds]` early return (:732-734) stays because the delete path posts that notification with `Set<Feed>`.
- **adapt (PR3)** `Mac/MainWindow/SharingServicePickerDelegate.swift` (50 lines) — Share picker delegate; loses the MarsEdit and Micro.blog custom services (:32) with `Shared/ExtensionPoints`.
- **adapt (PR9)** `Mac/MainWindow/Timeline/ArticlePasteboardWriter.swift` (193 lines) — Article drag/copy/share payload; its `article.feed` reads become site substitutions.
- **keep** `Mac/MainWindow/ColumnLayoutSplitView.swift` (18 lines) — Split view subclass for column layout.
- **keep** `Mac/MainWindow/Detail/Base.lproj/DetailView.xib` — Detail pane nib.
- **keep** `Mac/MainWindow/Detail/DetailContainerView.swift` (51 lines) — Container hosting the web view under the status bar.
- **keep** `Mac/MainWindow/Detail/DetailStatusBarView.swift` (74 lines) — Hover-link status bar fed by `main_mac.js` messages.
- **keep** `Mac/MainWindow/Detail/DetailWebView.swift` (139 lines) — WKWebView subclass with keyboard delegate, toolbar insets and trimmed context menu.
- **keep** `Mac/MainWindow/Detail/Keyboard/DetailKeyboardDelegate.swift` (40 lines) — Detail-pane shortcuts from `DetailKeyboardShortcuts.plist`.
- **keep** `Mac/MainWindow/Detail/blank.html` (6 lines) — Initial blank load that avoids a white flash.
- **keep** `Mac/MainWindow/Detail/main_mac.js` (43 lines) — Scroll reporting, link hover messages and `selectedHTML()`.
- **keep** `Mac/MainWindow/Detail/page.html` (12 lines) — Mac page wrapper with `[[title]]`, `[[style]]`, `<base href=[[baseURL]]>` and `[[body]]`.
- **keep** `Mac/MainWindow/IconView.swift` (133 lines) — Icon view used by the sidebar cell, the timeline cell and `DetailIconSchemeHandler`; shows the site favicon.
- **keep** `Mac/MainWindow/Keyboard/MainWindowKeyboardHandler.swift` (32 lines) — Loads `GlobalKeyboardShortcuts.plist`; the previous/next-subscription entries in the plist go with their actions.
- **keep** `Mac/MainWindow/MainWindowState.swift` (70 lines) — Secure-coded window restoration state.
- **keep** `Mac/MainWindow/SharingServiceDelegate.swift` (32 lines) — NSSharingService delegate.
- **keep** `Mac/MainWindow/Sidebar/Cell` (278 lines) — Sidebar cell, appearance and layout (icon, name, unread count).
- **keep** `Mac/MainWindow/Sidebar/Keyboard/SidebarKeyboardDelegate.swift` (41 lines) — Loads `SidebarKeyboardShortcuts.plist`.
- **keep** `Mac/MainWindow/Sidebar/SidebarOutlineView.swift` (50 lines) — Outline view subclass with context menu and `PseudoFeed` check.
- **keep** `Mac/MainWindow/Sidebar/SidebarWindowState.swift` (45 lines) — Sidebar restoration state.
- **keep** `Mac/MainWindow/Sidebar/UnreadCountView.swift` (142 lines) — Unread badge.
- **keep** `Mac/MainWindow/Timeline/Cell` (903 lines) — Timeline cell view, layout, appearance, cell data and unread indicator; the feed-name field carries the site.
- **keep** `Mac/MainWindow/Timeline/Keyboard/TimelineKeyboardDelegate.swift` (43 lines) — Loads `TimelineKeyboardShortcuts.plist`.
- **keep** `Mac/MainWindow/Timeline/TimelineContainerViewController.swift` (303 lines) — Hosts the regular and search timelines, sort menu and read filter; `timelineRequestedFeedSelection` (:207) can go.

## Mac/NetNewsWire-Bridging-Header.h

- **keep** `Mac/NetNewsWire-Bridging-Header.h` (10 lines) — Imports `WKPreferencesPrivate.h` and `NSOpenPanel+Extras.h`.

## Mac/Preferences

- **delete (PR5)** `Mac/Preferences/Accounts` (1467 lines) — Accounts pane, Add Account picker and per-service credential sheets (all files, 2,633 lines including nibs); the Feedbin, NewsBlur and ReaderAPI controllers and xibs fall out in PR2 and the rest, including `AccountsAddCloudKitWindowController`, in PR5 when the single iCloud account is created automatically.
- **delete (PR1)** `Mac/Preferences/Advanced` (72 lines) — Sparkle update-channel pane (controller, xib and xcstrings).
- **adapt (PR3)** `Mac/Preferences/General/GeneralPrefencesViewController.swift` (230 lines) — General pane (text size, theme, default browser); loses `subscribeToFeedsInDefaultBrowser` (:224-227, PR3) and the refresh-interval popup in its xib (PR5), and relabels the JavaScript switch "Allow JavaScript when showing the original page" (PR7).
- **adapt (PR1)** `Mac/Preferences/PreferencesWindowController.swift` (203 lines) — Toolbar-style preferences window; drops the Advanced pane (PR1) and the Accounts pane (PR5) and gains an iCloud pane with Reset iCloud Sync.

## Mac/Resources

- **delete (PR4)** `Mac/Resources/NetNewsWire.provisionprofile` — Ranchero's Mac provisioning profile (already excluded from the target at pbxproj:310); removed with its exception-set entry.
- **delete (PR3)** `Mac/Resources/NetNewsWire.sdef` — Scripting definition referenced by `OSAScriptingDefinition`.
- **delete (PR4)** `Mac/Resources/container-migration.plist` (10 lines) — Sandbox container migration for existing NetNewsWire installs.
- **delete (PR4)** `Mac/Resources/NetNewsWire-dev.entitlements` (23 lines) — Developer entitlements with no iCloud, CloudKit or aps keys and the sandbox off (:5-6); both `-dev` files go so one entitlements set remains and the Mac Debug build becomes sandboxed.
- **adapt (PR1)** `Mac/Resources/Info.plist` (145 lines) — Mac Info.plist; loses the Sparkle keys (:49-50, :78-81, PR1) and `NSAppleScriptEnabled`, `OSAScriptingDefinition`, `NSAppleEventsUsageDescription` (:60-63, :74-75, PR3), then in PR4 gains the `netnewslist` scheme in place of `netnewswire`/`feed`/`feeds`/`x-netnewswire-feed` (:36), a corrected `CFBundleURLName` (:34-35), the `CloudKitContainerIdentifier` key and renamed UserAgent strings (:82-85), while `NSAllowsArbitraryLoads` (:55-58) and `AppGroup` (:5-6) must survive.
- **adapt (PR1)** `Mac/Resources/NetNewsWire.entitlements` (42 lines) — Full Mac entitlements; loses the Sparkle mach-lookup (:36-40, PR1), the MarsEdit apple-events exception and `automation.apple-events` (:25-26, :31-35, PR3), then in PR4 gets container `iCloud.$(ORG).NetNewsList`, a Team-ID-prefixed app group, `aps-environment = development` and no hardcoded `icloud-container-environment` (:5-8), and finally drops the kvstore identifier (:17-18) once the C7 preference is gone (PR5).
- **adapt (PR12)** `Mac/Resources/Assets.xcassets` — Mac asset catalog; the account-service imagesets and colors go with the `Shared/Assets.swift` switch.

## Mac/SafariExtension

- **delete (PR3)** `Mac/SafariExtension` (97 lines) — "Subscribe to Feed" Safari App Extension (handler, Info.plist, entitlements, toolbar icon, all files); removed with its target `6581C73220CED60000F4AD34`, exception set and xcconfig.

## Mac/Scripting

- **delete (PR3)** `Mac/Scripting` (1327 lines) — AppleScript object model plus `AppDelegate+Scriptability.swift`, whose kAEGetURL registration and `netnewswire://theme/` branch (:46-67) move first into the new ~40-line `Mac/AppDelegate+URLHandling.swift` (the `add` branch arrives in PR8); the `addFeed` fall-through (:76-83) is not carried over.

## Mac/ShareExtension

- **adapt (PR8)** `Mac/ShareExtension/Base.lproj/ShareViewController.xib` — Share extension nib; loses the folder popup.
- **adapt (PR4)** `Mac/ShareExtension/Info.plist` (53 lines) — Share-services extension point with a one-web-URL activation rule and `SafariExt` preprocessing; the hardcoded `group.$(ORGANIZATION_IDENTIFIER).NetNewsWire-Evergreen` AppGroup (:7-8) becomes `$(APP_GROUP_ID)` and the display name is renamed.
- **adapt (PR4)** `Mac/ShareExtension/ShareExtension.entitlements` (14 lines) — Sandbox plus `$(APP_GROUP_ID)`; only the group value changes, and no CloudKit entitlement is added because extensions never write to CloudKit.
- **adapt (PR8)** `Mac/ShareExtension/ShareViewController.swift` (166 lines) — Mac share extension; keeps URL resolution (:36-94) and `send()` (:96-107), drops the folder popup (:118-164) and enqueues a `SavedArticleRequest`.

## Mac/WKPreferencesPrivate.h

- **keep** `Mac/WKPreferencesPrivate.h` (15 lines) — Declares the private `_developerExtrasEnabled` used only for the Web Inspector toggle.

## Modules/Account

- **delete** `Modules/Account/Sources/Account/AccountBehaviors.swift` (51 lines) — Per-service UI capability flags whose readers (OPML import, folder pickers, drag and drop) are all deleted by PR9/PR10; goes with the last of them.
- **delete** `Modules/Account/Sources/Account/AccountSettingsDatabase.swift` (61 lines) — Read-only legacy AccountSettings.db migration reader; nothing to migrate.
- **delete** `Modules/Account/Sources/Account/AccountSettingsImporter.swift` (100 lines) — One-time Settings.plist import; nothing to migrate.
- **delete (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitStats.swift` (69 lines) — Stats and clean-up plan value types for the retention model C6 removes.
- **delete (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitStatsViewModel.swift` (263 lines) — View model for the iCloud Stats screens; goes with C6.
- **delete (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitWebDocumentation.swift` (13 lines) — Link to netnewswire.com's iCloud help page, read only by the account UI deleted in PR5.
- **delete (PR10)** `Modules/Account/Sources/Account/FeedSettingsImporter.swift` (116 lines) — One-time FeedMetadata.plist import; deleted with the `readerViewAlwaysEnabled` column and its test.
- **delete (PR2)** `Modules/Account/Sources/Account/Feedbin` (1861 lines) — Feedbin delegate, API caller and DTOs.
- **delete (PR2)** `Modules/Account/Sources/Account/Feedly` (3164 lines) — Feedly delegate, OAuth flow, API caller and models.
- **delete (PR5)** `Modules/Account/Sources/Account/LocalAccount` (898 lines) — On My Mac delegate, `LocalAccountRefresher` and `InitialFeedDownloader` (all files); `CloudKitAccountDelegate` stops using the refresher in the same PR (C10), which leaves RSWeb `DownloadSession` dead.
- **delete (PR2)** `Modules/Account/Sources/Account/NewsBlur` (993 lines) — NewsBlur delegate on top of `Modules/NewsBlur`.
- **delete (PR2)** `Modules/Account/Sources/Account/ReaderAPI` (2343 lines) — Google Reader API delegate for FreshRSS, Inoreader, BazQux and The Old Reader.
- **delete (PR2)** `Modules/Account/Sources/Account/SyncRateLimiter.swift` (70 lines) — Retry-After backoff used only by Feedly and ReaderAPI.
- **delete (PR2)** `Modules/Account/Sources/Account/URLRequest+Account.swift` (79 lines) — Credentialed `URLRequest` initializer importing NewsBlur and Secrets, used only by the four sync callers.
- **adapt (PR2)** `Modules/Account/Package.swift` (60 lines) — Manifest; drops NewsBlur (PR2), then FeedFinder and Secrets (PR5).
- **adapt (PR2)** `Modules/Account/Sources/Account/Account.swift` (1590 lines) — Central account owning the database, feed tree, unread counts, `FetchType` dispatch and article update/status APIs; `AccountType` shrinks to `.cloudKit` (:52-78, :297-316, PR2/PR5), `updateAsync(feedIDsAndItems:)` (:944) goes with L4 (PR2), Credentials/OAuth (:356-454) and `importOPML` (:515-534) go (PR5), `deleteOlder` defaults to `false` (:933, L1), the stats passthroughs go (C6), `FetchType.read(limit)` is added to both `fetchArticles` switches (:808-856, PR6), and the OPML load/save path (:256, :344, :554-594) stays because the reading-list feed lives in the OPML tree.
- **adapt (PR5)** `Modules/Account/Sources/Account/AccountDelegate.swift` (70 lines) — Backend protocol; loses `credentials`, `validateCredentials` (:27, :61) and `importOPML`, and either gains `storeArticleChanges` or `Account+ReadingList.swift` casts to `CloudKitAccountDelegate`.
- **adapt (PR2)** `Modules/Account/Sources/Account/AccountError.swift` (138 lines) — Error enum; loses the credentials cases (PR2) and the feed-subscribe and OPML cases (PR5), keeps `detailedErrorMessage` for ErrorLog.
- **adapt (PR3)** `Modules/Account/Sources/Account/AccountManager.swift` (718 lines) — Account registry; `anyAccountHasNetNewsWireNewsSubscription` (:405) goes in PR3, then in PR5 `defaultAccount` becomes the single iCloud account (:152) guarded by `Platform.deviceHasiCloudAccount`, `createAccount`/`deleteAccount` (:185, :212), the folder scan (:624-718) and the C7 kvstore mirror (:39-53, :556-600) go, and `refreshProgressInfo` is re-sourced from `syncProgress`.
- **adapt (PR5)** `Modules/Account/Sources/Account/AccountSettings.swift` (252 lines) — Per-account UserDefaults settings; keeps name, isActive, externalID and the last-refresh dates, drops username, endpointURL, conditionalGetInfo and the plist/db migration fallbacks (:148-160, :192-220).
- **adapt (PR5)** `Modules/Account/Sources/Account/CloudKit` (3486 lines) — The one surviving delegate and both zones; ~900 lines of stats, cleanup and scan code go and the content-gating rules flip (section 4 of the plan).
- **adapt (PR4)** `Modules/Account/Sources/Account/CloudKit/CloudKitAccountDelegate.swift` (1240 lines) — The AccountDelegate: the container id comes from `CloudKitContainerIdentifier` instead of the `as! String` at :42-45 (PR4); in PR5 C10 removes `refresher` (:52, :107-110, :760-765), `LocalAccountRefresherDelegate` (:1231-1240) and the RSS half of `initialRefreshAll`/`performRefreshAll`, `createFeed` becomes `addDeadFeed` alone with `serverRecordChanged` as success and no tree removal on failure (:938-958, :1043-1067), the `userDeletedZone` teardown (:888-895) becomes token reset plus `ensureReadingListFeed()`, `storeArticleChanges` (:1102-1122) loses the unread filter and queues `.content` for updates (C0, C5), `cleanUpContentRecordsIfNeeded`, `fetchCloudKitStats` and `cleanUpCloudKit` (:725-760, :1195-1230) go (C6), `subscribeToZoneChangesWithActivity` runs unconditionally (C9); `accountDidInitialize` (:686-701) is rewritten as one sequence in PR6.
- **adapt (PR6)** `Modules/Account/Sources/Account/CloudKit/CloudKitAccountZone.swift` (324 lines) — Account zone with the deterministic `AccountWebFeed` record name (`url.md5String`, :95) and `findOrCreateAccount` (:201-262); kept in v1 because it makes the synthetic feed converge across devices, `createFeed` is called by `ensureReadingListFeed()`, the OPML-import path goes (PR5), and full removal is optional follow-up 2.
- **adapt (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitAccountZoneDelegate.swift` (217 lines) — Applies Account-zone records to the local tree and dedupes by `existingFeed(withExternalID:)` (:182-192), which is how device 2 adopts the reading-list feed; folder handling becomes dormant.
- **adapt (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitArticleStatusUpdate.swift` (75 lines) — Classifies a queued article as `.new`, `.all`, `.statusOnly` or `.delete` (:40-58); reclassified per C0/C2 (lone `.new` -> `.new`, any `.content` or `.new` with company -> `.all`, pure flips stay `.statusOnly`) and loses the `syncArticleContentForUnreadArticles` parameter (:31, :52, C7).
- **adapt (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitArticlesZone.swift` (786 lines) — Articles zone building status and content records (:706-764) with LZFSE compression (:766-788); `saveNewArticles` (:151-161) and `modifyArticles` (:194-213) always send content (C1, C3), the `.statusOnly` content delete (:211) goes (C4), the ~440 lines of cleanup, scan and stats (:248-690) go (C6), the C7 constructor closure (:113) goes, and a `contentHTMLAsset` CKAsset spill above ~700 KB is added (C8).
- **adapt (PR6)** `Modules/Account/Sources/Account/CloudKit/CloudKitArticlesZoneDelegate.swift` (178 lines) — Inbound path with pending-status guards (:81-92), deletes (:69-79) and `makeParsedItem` -> `updateAsync(deleteOlder: false)` (:106, :122-160); `makeParsedItem` also reads the CKAsset, and the delete path relies on `Account.delete(articleIDs:)` removing both rows.
- **adapt (PR5)** `Modules/Account/Sources/Account/CloudKit/CloudKitSendStatusOperation.swift` (142 lines) — Drains SyncDatabase in blocks of 150, fetches articles and calls `modifyArticles` (:295-351); loses the C7 closure parameter and keeps the `.content` row when the content modify fails so the next send retries.
- **adapt (PR5)** `Modules/Account/Sources/Account/CombinedRefreshProgress.swift` (87 lines) — Merges per-account `ProgressInfo` for the status bar and the iOS progress view; re-sourced from `syncProgress` when `refresher` goes (C10) or deleted with that UI (open question 10).
- **adapt (PR5)** `Modules/Account/Sources/Account/DataExtensions.swift` (64 lines) — `Feed.SettingKey`, `Feed.takeSettings(from: ParsedFeed)` and `Article.account`/`Article.feed`; the RSS-only `takeSettings` goes with the refreshers and the `readerViewAlwaysEnabled` key (:29) in PR10.
- **adapt (PR10)** `Modules/Account/Sources/Account/Feed.swift` (338 lines) — Feed model that the single "Reading List" feed instantiates (`url == feedID == "netnewslist://reading-list"`, `externalID = url.md5String`); `readerViewAlwaysEnabled` (:147-153) goes in PR10, the HTTP-refresh fields (:102-136, :175-194) are dead after PR5 and go with the optional RSWeb diet, and `OPMLRepresentable` (:296-322) stays for the persisted tree.
- **adapt (PR10)** `Modules/Account/Sources/Account/FeedSettings.swift` (204 lines) — Per-feed settings backed by `FeedSettingsDatabase`; loses the `readerViewAlwaysEnabled` column in PR10, with the HTTP-refresh columns (:99, :122) dead after PR5.
- **adapt (PR10)** `Modules/Account/Sources/Account/FeedSettingsDatabase.swift` (333 lines) — SQLite `feedSettings` table keyed by feed URL; drops the `readerViewAlwaysEnabled` column (:25), and the startup row sweep against the OPML tree (Account.swift:345) is harmless with one feed.
- **adapt (PR9)** `Modules/Account/Sources/Account/SidebarItemIdentifier.swift` (101 lines) — Persisted `smartFeed`/`feed`/`folder` identifier used by state restoration, read-filter tables and the icon cache; the `assertionFailure` in `init?(userInfo:)` (:97) goes when the `feed`/`folder` cases do, or Debug builds trap on an old restoration state.
- **adapt (PR2)** `Modules/Account/Tests/AccountTests` (2235 lines) — Account tests; the Feedbin, Feedly, NewsBlur and ReaderAPI folders, the `JSON/` fixtures, `IsolatedWebserviceResponsesTrait*` and `TestingURLProtocol+Responses` go in PR2, `AccountCredentialsTest` and the settings-importer tests in PR5, `FeedSettingsImporterTests` in PR10, `AccountOPMLLoadTests` and `TestAccountManager` stay, and the PR5 regression tests (`record` classification, `ArticleRecordPlanner`) are added here.
- **keep** `Modules/Account/Sources/Account/ArticleFetcher.swift` (82 lines) — `ArticleFetcher` protocol with Feed and Folder conformances; the timeline's only input type.
- **keep** `Modules/Account/Sources/Account/CloudKit/CKRecord+Extensions.swift` (22 lines) — `externalID = recordName` helpers.
- **keep** `Modules/Account/Sources/Account/CloudKit/CloudKitReceiveStatusOperation.swift` (55 lines) — Wraps `articlesZone.refreshArticles()` with activity logging.
- **keep** `Modules/Account/Sources/Account/CloudKit/CloudKitRemoteNotificationOperation.swift` (59 lines) — On silent push fetches the Account zone then the Articles zone; unchanged while both zones stay.
- **keep** `Modules/Account/Sources/Account/CloudKit/CloudKitSyncMessage.swift` (43 lines) — ActivityLog helpers for CloudKit sub-activities.
- **keep** `Modules/Account/Sources/Account/Container.swift` (163 lines) — Container protocol over the feed/folder tree; `existingFeed(withURL:)` (:38, :110) is what `ensureReadingListFeed()` uses.
- **keep** `Modules/Account/Sources/Account/ContainerIdentifier.swift` (100 lines) — Codable container identity used by persisted sidebar and selection state.
- **keep** `Modules/Account/Sources/Account/ContainerPath.swift` (49 lines) — Undo helper for `DeleteCommand`; dead after PR9 but harmless.
- **keep** `Modules/Account/Sources/Account/Folder.swift` (228 lines) — Folder model with unread aggregation and OPML output; dormant once no UI creates folders, kept for Container and Account-zone compatibility.
- **keep** `Modules/Account/Sources/Account/OPMLFile.swift` (129 lines) — Loads and saves `Subscriptions.opml`, the persisted feed/folder tree that `Account.init` reads (Account.swift:344); the reading-list feed lives in it, so the file stays.
- **keep** `Modules/Account/Sources/Account/OPMLNormalizer.swift` (66 lines) — Flattens nested OPML into one level; used by `loadOPMLItems` (Account.swift:593) on every launch, not only by import.
- **keep** `Modules/Account/Sources/Account/SidebarItem.swift` (36 lines) — `SidebarItem` protocol and `ReadFilterType`; every sidebar item, including `PseudoFeed`, conforms.
- **keep** `Modules/Account/Sources/Account/SingleArticleFetcher.swift` (38 lines) — `ArticleFetcher` for one article id, used by deep links and restoration.
- **keep** `Modules/Account/Sources/Account/UnreadCountProvider.swift` (43 lines) — Unread-count protocol and notifications behind the badges.

## Modules/Articles

- **adapt (PR5)** `Modules/Articles/Sources/Articles/ArticleStatus.swift` (103 lines) — Mutable read/starred/dateArrived status; `staleIntervalInSeconds` (:16) goes with L3, and no `archived` key is added because Archive = `read`.
- **keep** `Modules/Articles/Sources/Articles/Article.swift` (94 lines) — Immutable model with `articleID = md5(feedID + " " + uniqueID)` (:56-58), which is why canonical-URL `uniqueID`s give both devices the same id; no schema change.
- **keep** `Modules/Articles/Sources/Articles/Author.swift` (78 lines) — Author struct with JSON storage in the `authors` column; carries Readability bylines.
- **keep** `Modules/Articles/Sources/Articles/AuthorCache.swift` (55 lines) — Interning cache for `Author`.

## Modules/ArticlesDatabase

- **delete** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/AuthorsSchemaMigration.swift` (150 lines) — One-time legacy authors-table migration that runs a detached Task on every init; nothing to migrate.
- **adapt (PR2)** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/ArticlesDatabase.swift` (590 lines) — Public API and schema DDL (:434-446); `RetentionStyle` and the `deleteOldArticles` gate (:48-51, :422-424) and the `feedIDsAndItems` update go in PR2 (L4), the `deleteArticlesNotInSubscribedToFeedIDs` call (:425) goes in PR5 (L2), `fetchReadArticles`/`fetchReadArticlesAsync` wrappers mirroring :136 and :212 are added in PR6, and `DROP TABLE IF EXISTS tags` (:88) stays as the reason never to add a tags table.
- **adapt (PR2)** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/ArticlesTable.swift` (1047 lines) — Table logic where `update(parsedItems:feedID:deleteOlder:)` (:209-270) stays as the inbound path; `deleteOldArticles`/`articleCutoffDate` (:31, :562-588) go in PR2 (L4), the `deleteOlder` diff (:252-260, L1), the 183-day read-on-insert split (:229-236, L3) and `deleteArticlesNotInSubscribedToFeedIDs` (:618-635, L2) go in PR5, `deleteOldStatuses` (:590-608) stays for orphan statuses, `delete(articleIDs:)` (:345) gains a status-row delete, and `fetchReadArticles` mirrors `fetchUnreadArticles` (:794-805, PR6).
- **adapt (PR5)** `Modules/ArticlesDatabase/Tests/ArticlesDatabaseTests` (351 lines) — ArticleUpdate, TodayQueries and StatusDivergence tests; gain the PR5 retention regression test (two-year-old `dateArrived` with nil `datePublished` survives startup cleanup and a disjoint update, and delete removes the status row).
- **keep** `Modules/ArticlesDatabase/Package.swift` (46 lines) — Depends on Articles, RSCore, RSParser and RSDatabase.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/Constants.swift` (52 lines) — Table and column name constants; no new columns.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/Extensions/Article+Database.swift` (213 lines) — Row <-> Article mapping, `Article(parsedItem:)` and `changesFrom`; unchanged because the schema is unchanged.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/Extensions/ArticleStatus+Database.swift` (26 lines) — Status row mapping; no archived column.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/Extensions/Author+Database.swift` (27 lines) — `ParsedAuthor` -> `Author`; needed because `ParsedItem` remains the ingestion DTO.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/Extensions/ParsedArticle+Database.swift` (22 lines) — `ParsedItem.articleID`; needed for the same reason.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/Operations/FetchAllUnreadCountsOperation.swift` (71 lines) — Unread counts grouped by feedID behind `Account.fetchAllUnreadCounts`; works with one feed.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/SearchTable.swift` (247 lines) — FTS4 index over title and body (contentHTML then contentText, HTML stripped); exactly the full-text search the reading list wants.
- **keep** `Modules/ArticlesDatabase/Sources/ArticlesDatabase/StatusesTable.swift` (358 lines) — Status rows: `ensureStatusesForArticleIDs` creates with `dateArrived = now` (the date-saved), `mark`, repair and flag fetches.

## Modules/CloudKitSync

- **adapt (PR5)** `Modules/CloudKitSync/Sources/CloudKitSync/CloudKitError.swift` (106 lines) — Human-readable CKError descriptions; the `.userDeletedZone`, `.corruptAccount` and `.notAuthenticated` texts (:62-71) stop telling the user to remove and re-add the account.
- **keep** `Modules/CloudKitSync/Package.swift` (32 lines) — Generic CloudKit zone and operation layer depending only on RSCore.
- **keep** `Modules/CloudKitSync/Sources/CloudKitSync/CloudKitLogger.swift` (12 lines) — Shared Logger for CloudKit.
- **keep** `Modules/CloudKitSync/Sources/CloudKitSync/CloudKitZone.swift` (1016 lines) — Generic zone protocol: change tokens in `UserDefaults.standard` (:95-100), idempotent subscriptions (`subscriptionID = zoneID.zoneName`, :163), `save`/`saveIfNew`/`modify`/`delete`, fetch-changes and all CKError recovery; `resetChangeToken()` is what Reset iCloud Sync calls.
- **keep** `Modules/CloudKitSync/Sources/CloudKitSync/CloudKitZoneResult.swift` (84 lines) — Maps CKError codes, including partial failures, to the retry/zoneNotFound/limitExceeded enum.
- **keep** `Modules/CloudKitSync/Tests/CloudKitSyncTests/CloudKitSyncTests.swift` (12 lines) — Empty placeholder test.

## Modules/FeedFinder

- **delete (PR5)** `Modules/FeedFinder` (576 lines) — Feed discovery package (`FeedFinder`, `FeedSpecifier`, `HTMLFeedFinder`, `Package.swift`, tests, all files); removed from `Account/Package.swift` and the test plans once `createRSSFeed`'s `FeedFinder.find(url:)` call (CloudKitAccountDelegate.swift:946) goes with C10.

## Modules/HTMLMetadata

- **keep** `Modules/HTMLMetadata` (685 lines) — Actor-based cache of page `<head>` metadata (`HTMLMetadataDatabase`, `HTMLMetadataDownloader`, `HTMLMetadataRecord`, `HTMLMetadataTable`, `HTMLMetadataNotification`, `Package.swift`, all files) consumed by `FaviconDownloader` and `FeedIconDownloader` in Images and vacuumed by `AppDelegate+Shared.swift`; kept as-is, with the `feedLinks` field as harmless residue.

## Modules/Images

- **delete** `Modules/Images/Sources/Images/FeedIconDownloader.swift` (262 lines) — Feed icon discovery typed on `Feed`; dead once `IconImageCache` is re-keyed by host in PR9.
- **delete** `Modules/Images/Sources/Images/FeedIconURLTable.swift` (48 lines) — `feedIconURL` table access; goes with `FeedIconDownloader`.
- **adapt (PR9)** `Modules/Images/Package.swift` (41 lines) — Depends on RSCore, RSDatabase, RSWeb, Account, Articles, HTMLMetadata and ActivityLog; the Account dependency exists only for `Feed` and can go with the feed-typed entry points.
- **adapt (PR9)** `Modules/Images/Sources/Images/FaviconDownloader.swift` (333 lines) — Favicon discovery; `favicon(withHomePageURL:)` (:141) is the API `SiteFaviconCache` builds on, while `faviconAsIcon(for: Feed)` goes.
- **adapt (PR9)** `Modules/Images/Sources/Images/ImageMetadataDatabase.swift` (163 lines) — SQLite with downloadFailure, homePageFavicon and feedIconURL tables; drops the feed table.
- **keep** `Modules/Images/Sources/Images/AuthorAvatarDownloader.swift` (107 lines) — Author avatar download by `Author.avatarURL`.
- **keep** `Modules/Images/Sources/Images/ColorHash.swift` (75 lines) — Deterministic color from a string, used by `FaviconGenerator`.
- **keep** `Modules/Images/Sources/Images/DownloadFailureTable.swift` (60 lines) — downloadFailure table access.
- **keep** `Modules/Images/Sources/Images/FaviconGenerator.swift` (53 lines) — Letter-icon fallback for a host.
- **keep** `Modules/Images/Sources/Images/HomePageFaviconTable.swift` (56 lines) — Host-keyed favicon table.
- **keep** `Modules/Images/Sources/Images/IconImage.swift` (118 lines) — `IconImage` wrapper with luminance detection used by sidebar and timeline icons.
- **keep** `Modules/Images/Sources/Images/ImageDownloader.swift` (202 lines) — Icon-sized URL -> Data downloader with a 3-day-purged disk cache; stays for favicons, while offline article images get their own store under Application Support in PR11.
- **keep** `Modules/Images/Sources/Images/SingleFaviconDownloader.swift` (188 lines) — Downloads one favicon URL for `FaviconDownloader`.

## Modules/NewsBlur

- **delete (PR2)** `Modules/NewsBlur` (843 lines) — Standalone NewsBlur API package (all files) consumed only by the NewsBlur delegate and `URLRequest+Account`.

## Modules/RSCore

- **delete** `Modules/RSCore/Sources/RSCore/SendToBlogEditorApp.swift` (128 lines) — MarsEdit-style send-to helper; dead once `Shared/ExtensionPoints` goes in PR3.
- **delete** `Modules/RSCore/Sources/RSCore/SendToCommand.swift` (47 lines) — Send-to protocol; dead once ExtensionPoints and its use in `SharingServicePickerDelegate` go in PR3.
- **adapt (PR4)** `Modules/RSCore/Sources/RSCore/Logging.swift` (19 lines) — Logger subsystem hardcoded to `com.ranchero.NetNewsWire` (:18); renamed with the other identity strings.
- **adapt (PR5)** `Modules/RSCore/Sources/RSCore/String+RSCore.swift` (336 lines) — `mayBeURL` (:138) and `normalizedURL` (:165) validate pasted URLs for the Add Article sheet; `hmacUsingSHA1` becomes dead with the Mercury extractor and the `feed:` branch can go.
- **keep** `Modules/RSCore/Sources/RSCore/BinaryDiskCache.swift` (91 lines) — Thread-safe file-per-key Data cache.
- **keep** `Modules/RSCore/Sources/RSCore/Cache.swift` (89 lines) — Generic TTL in-memory cache used by `DownloadCache`.
- **keep** `Modules/RSCore/Sources/RSCore/Data+RSCore.swift` (219 lines) — `Data.isProbablyHTML` (:137), the right guard before handing a fetched body to the extractor.
- **keep** `Modules/RSCore/Sources/RSCore/MacroProcessor.swift` (86 lines) — `[[key]]` template substitution behind `ArticleRenderer`.
- **keep** `Modules/RSCore/Sources/RSCore/OPMLRepresentable.swift` (21 lines) — OPML output protocol that `Feed`, `Folder` and `Account` conform to; `OPMLFile.save` writes the persisted tree through it.
- **keep** `Modules/RSCore/Sources/RSCore/Platform.swift` (110 lines) — `deviceHasiCloudAccount` (:16-17) gates the single iCloud account.
- **keep** `Modules/RSCore/Sources/RSCore/StripHTML.swift` (335 lines) — HTML stripper used for timeline summaries and search text.

## Modules/RSDatabase

- **adapt (PR4)** `Modules/RSDatabase/Sources/RSDatabase/Logging.swift` (11 lines) — Logger subsystem hardcoded to `com.ranchero.NetNewsWire`; renamed with RSCore's.
- **keep** `Modules/RSDatabase/Sources/RSDatabase/DatabaseQueue.swift` (146 lines) — Serial queue and FMDatabase setup; `runCreateStatements` executes only `create` lines, so ALTERs run separately as `ArticlesDatabase.init` already does.
- **keep** `Modules/RSDatabase/Sources/RSDatabase/DatabaseTable.swift` (85 lines) — Table protocol helpers including `containsColumn`.
- **keep** `Modules/RSDatabase/Sources/RSDatabase/FMDatabase+Extras.swift` (127 lines) — Open, transaction and 13-day vacuum helpers.
- **keep** `Modules/RSDatabase/Sources/RSDatabase/FMResultSet+Extras.swift` (60 lines) — Result-set helpers.
- **keep** `Modules/RSDatabase/Sources/RSDatabase/RSDatabaseInfoTable.swift` (44 lines) — Per-database key/value table.
- **keep** `Modules/RSDatabase/Sources/RSDatabaseObjC` — Vendored FMDB plus RS extras.

## Modules/RSParser

- **delete** `Modules/RSParser/Sources/RSParser/Feeds/FeedParser.swift` (100 lines) — RSS/Atom/JSON Feed dispatcher; dead after PR5 and removed by the optional RSParser diet (follow-up 5).
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/FeedParserError.swift` (18 lines) — Feed parser error enum; goes with `FeedParser`.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/FeedType.swift` (60 lines) — Feed format sniffing; goes with `FeedParser`.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/JSON/JSONFeedParser.swift` (247 lines) — JSON Feed parser; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/JSON/RSSInJSONParser.swift` (182 lines) — RSS-in-JSON parser; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/ParsedFeed.swift` (41 lines) — Feed DTO used only by the refresh paths deleted in PR5 and `Feed.takeSettings(from:)`; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/ParsedHub.swift` (14 lines) — WebSub hub DTO; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/XML/AtomParser.swift` (503 lines) — Atom parser; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/XML/RSSItem.swift` (96 lines) — RSS item accumulator; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/Feeds/XML/RSSParser.swift` (360 lines) — RSS 2.0 parser; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/HTML/HTMLLink.swift` (21 lines) — DTO for `HTMLLinkParser`; goes with it.
- **delete** `Modules/RSParser/Sources/RSParser/HTML/HTMLLinkParser.swift` (99 lines) — Collects `<a href>` links; its only consumer is `HTMLFeedFinder`, deleted in PR5.
- **delete** `Modules/RSParser/Sources/RSParser/JSON/JSONTypes.swift` (12 lines) — JSON typealiases for the JSON feed parsers; optional diet.
- **delete** `Modules/RSParser/Sources/RSParser/JSON/JSONUtilities.swift` (24 lines) — JSON helpers for the JSON feed parsers; optional diet.
- **adapt** `Modules/RSParser/Package.swift` (37 lines) — Feed, OPML and HTML parsing manifest depending on RSCore and the remote Tidemark package; Tidemark (used only by `ParsedItem.swift:10, :70` for `markdown`) can go with the optional diet.
- **keep** `Modules/RSParser/Sources/RSParser/Feeds/Data+ProbablyFormat.swift` (146 lines) — `isProbablyXML`/`isProbablyJSON`/`isProbablyJSONFeed` sniffing; the plan's diet keeps it explicitly, although today only `FeedType` reads it.
- **keep** `Modules/RSParser/Sources/RSParser/Feeds/ParsedAttachment.swift` (35 lines) — Enclosure DTO referenced by `ParsedItem`.
- **keep** `Modules/RSParser/Sources/RSParser/Feeds/ParsedAuthor.swift` (39 lines) — Author DTO stored JSON-encoded in CloudKit `parsedAuthors` and mapped by `Author+Database`.
- **keep** `Modules/RSParser/Sources/RSParser/Feeds/ParsedItem.swift` (87 lines) — The 18-parameter ingestion DTO (:32-49) that `saveArticle` builds (`feedURL == feedID`) and `makeParsedItem` produces; the article-insert type of `ArticlesDatabase`, kept as-is.
- **keep** `Modules/RSParser/Sources/RSParser/Feeds/XML/OPMLParser.swift` (109 lines) — OPML parser that `OPMLFile.load` (:95) uses to read `Subscriptions.opml` on every launch; stays with the OPML tree.
- **keep** `Modules/RSParser/Sources/RSParser/HTML/HTMLAttributes.swift` (65 lines) — Case-insensitive attribute view for `HTMLScanner`.
- **keep** `Modules/RSParser/Sources/RSParser/HTML/HTMLMetadata.swift` (324 lines) — Categorizes head tags into favicons, apple-touch-icons, feed links and OpenGraph images for the HTMLMetadata module; `resolveFeedLinks` (:127-172) is harmless residue.
- **keep** `Modules/RSParser/Sources/RSParser/HTML/HTMLMetadataParser.swift` (97 lines) — Collects `<link>`/`<meta>` tags into `HTMLMetadata`.
- **keep** `Modules/RSParser/Sources/RSParser/HTML/HTMLRelativeURLResolver.swift` (408 lines) — Rewrites href/src/srcset against a base URL; no app consumer today, available to the extractor.
- **keep** `Modules/RSParser/Sources/RSParser/HTML/HTMLScanner.swift` (514 lines) — Liberal SAX-style HTML tokenizer behind `HTMLMetadataParser`.
- **keep** `Modules/RSParser/Sources/RSParser/HTML/HTMLTag.swift` (26 lines) — Collected tag value type.
- **keep** `Modules/RSParser/Sources/RSParser/OPML/OPMLAttributes.swift` (34 lines) — OPML attribute keys used by `OPMLParser` and `OPMLFile`.
- **keep** `Modules/RSParser/Sources/RSParser/OPML/OPMLDocument.swift` (20 lines) — OPML document root returned by `OPMLParser`.
- **keep** `Modules/RSParser/Sources/RSParser/OPML/OPMLError.swift` (26 lines) — OPML parse errors.
- **keep** `Modules/RSParser/Sources/RSParser/OPML/OPMLFeedSpecifier.swift` (21 lines) — Feed specifier read by `Account.addOPMLItems`.
- **keep** `Modules/RSParser/Sources/RSParser/OPML/OPMLItem.swift` (57 lines) — OPML item tree node built by the parser and `OPMLNormalizer`.
- **keep** `Modules/RSParser/Sources/RSParser/ParserData.swift` (21 lines) — (url, data) input pair for all parsers.
- **keep** `Modules/RSParser/Sources/RSParser/Utilities/DateParser.swift` (497 lines) — Liberal RFC 822 / ISO 8601 date parser; available for Readability's `publishedTime`.
- **keep** `Modules/RSParser/Sources/RSParser/Utilities/String+RSParser.swift` (16 lines) — `nilIfEmptyOrWhitespace`.
- **keep** `Modules/RSParser/Sources/RSParser/XML/String+HTMLEntities.swift` (59 lines) — `decodingHTMLEntities()` used by timeline formatting and search indexing.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLASCII.swift` (140 lines) — ASCII constants used by `HTMLScanner`, `HTMLRelativeURLResolver` and the XML scanner.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLAttributes.swift` (145 lines) — XML attribute view passed to the `OPMLParser` delegate.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLEncoding.swift` (330 lines) — Charset detection and transcoding for `XMLSAXParser`; stays with the OPML backbone.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLEntities.swift` (396 lines) — Entity decoder behind `HTMLScanner` and `String.decodingHTMLEntities()`.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLNamespace.swift` (77 lines) — Namespace enum used by the SAX parser and its delegates.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLNamespaceContext.swift` (65 lines) — Namespace prefix stack for `XMLSAXParser`.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLSAXParser.swift` (417 lines) — Pure-Swift SAX parser that `OPMLParser` (:18) drives; stays as long as the OPML tree does.
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLSAXParserDelegate.swift` (80 lines) — Delegate protocol implemented by `OPMLParserDelegate` (:53).
- **keep** `Modules/RSParser/Sources/RSParser/XML/XMLScanner.swift` (466 lines) — XML tokenizer behind `XMLSAXParser`.

## Modules/RSTree

- **delete** `Modules/RSTree/Sources/RSTree/RSTree.swift` (3 lines) — Leftover SPM template struct.
- **keep** `Modules/RSTree/Sources/RSTree/NSOutlineView+RSTree.swift` (57 lines) — Outline view reveal and select helpers.
- **keep** `Modules/RSTree/Sources/RSTree/Node.swift` (201 lines) — Generic tree node.
- **keep** `Modules/RSTree/Sources/RSTree/NodePath.swift` (38 lines) — Root-to-node path.
- **keep** `Modules/RSTree/Sources/RSTree/TopLevelRepresentedObject.swift` (15 lines) — Root placeholder object.
- **keep** `Modules/RSTree/Sources/RSTree/TreeController.swift` (124 lines) — Rebuilds the node tree from a delegate.

## Modules/RSWeb

- **delete** `Modules/RSWeb/Sources/RSWeb/CacheControlInfo.swift` (80 lines) — Cache-Control parsing for refresh scheduling; dead after PR5 but still typed into `Feed`, `FeedSettings` and `FeedSettingsDatabase`, whose HTTP fields go first (optional RSWeb diet).
- **delete (PR5)** `Modules/RSWeb/Sources/RSWeb/DownloadSession.swift` (571 lines) — Batch feed-refresh session whose only consumer is `LocalAccountRefresher`; dead after PR5 and deleted then or with the RSWeb diet.
- **delete (PR5)** `Modules/RSWeb/Tests/RSWebTests/DownloadSession429Tests.swift` (82 lines) — Tests for `DownloadSession`; go with it.
- **delete** `Modules/RSWeb/Sources/RSWeb/Dictionary+RSWeb.swift` (26 lines) — `urlQueryString`, used only by `SendToMicroBlogCommand`; dead after PR3.
- **delete** `Modules/RSWeb/Sources/RSWeb/HTTPConditionalGetInfo.swift` (46 lines) — ETag/Last-Modified for conditional GET; same `Feed`/`FeedSettings` dependency as `CacheControlInfo`.
- **delete** `Modules/RSWeb/Sources/RSWeb/HTTPDateInfo.swift` (30 lines) — HTTP Date header parsing for refresh; dead after PR5.
- **delete** `Modules/RSWeb/Sources/RSWeb/HTTPLinkPagingInfo.swift` (39 lines) — Link-header paging for sync APIs; dead after PR2.
- **delete** `Modules/RSWeb/Sources/RSWeb/HTTPResponse429.swift` (37 lines) — Retry-After bookkeeping used only by `DownloadSession`.
- **delete** `Modules/RSWeb/Sources/RSWeb/URLComponents+RSWeb.swift` (34 lines) — `enhancedPercentEncodedQuery`, used only by `URLRequest+Account`; dead after PR2.
- **delete** `Modules/RSWeb/Sources/RSWeb/URLRequest+RSWeb.swift` (28 lines) — `addBasicAuthorization`, used only by sync accounts; dead after PR2.
- **delete** `Modules/RSWeb/Sources/RSWeb/WebServices/TestingURLProtocol.swift` (157 lines) — URLProtocol stub for sync-account tests; after PR2 only its own RSWeb tests use it.
- **delete** `Modules/RSWeb/Sources/RSWeb/WebServices/URLSession+Webservice.swift` (139 lines) — REST session helper for the four sync services; dead after PR2.
- **delete** `Modules/RSWeb/Sources/RSWeb/WebServices/URLSession+WebserviceJSON.swift` (59 lines) — JSON send/decode helpers for the same services; dead after PR2.
- **adapt** `Modules/RSWeb/Package.swift` (34 lines) — Declares a dependency on RSParser (:14, :21) that no RSWeb source imports; drop it.
- **adapt** `Modules/RSWeb/Sources/RSWeb/SpecialCases.swift` (170 lines) — Host special cases and `extendedUserAgent`; keep `extendedUserAgent` (Downloader.swift:113), `localeForLowercasing` and `urlStringMatchesDomain`, drop the RSS-host cases.
- **adapt (PR4)** `Modules/RSWeb/Sources/RSWeb/UserAgent.swift` (46 lines) — `browserUserAgent` (:31) is a `@MainActor static var` filled at launch that `ExtractionCoordinator` copies for `PageFetcher`; the Info.plist UA strings are renamed and `.specialCaseFeed` can go.
- **keep** `Modules/RSWeb/Sources/RSWeb/DownloadCache.swift` (53 lines) — 180-second in-memory cache of `Downloader` responses (:25), one reason `Downloader` must not fetch pages.
- **keep** `Modules/RSWeb/Sources/RSWeb/DownloadResponse.swift` (25 lines) — `Downloader` return type.
- **keep** `Modules/RSWeb/Sources/RSWeb/Downloader.swift` (157 lines) — `@MainActor` one-shot downloader with one connection per host, no explicit timeout and cached error bodies (:117-120); kept for favicons and metadata, never for page fetching (`PageFetcher` uses `URLSession`).
- **keep** `Modules/RSWeb/Sources/RSWeb/HTTPMethod.swift` (17 lines) — Method constants.
- **keep** `Modules/RSWeb/Sources/RSWeb/HTTPRequestHeader.swift` (21 lines) — Header name constants.
- **keep** `Modules/RSWeb/Sources/RSWeb/HTTPResponseCode.swift` (73 lines) — Status code constants.
- **keep** `Modules/RSWeb/Sources/RSWeb/HTTPResponseHeader.swift` (28 lines) — Header name constants.
- **keep** `Modules/RSWeb/Sources/RSWeb/MacWebBrowser.swift` (260 lines) — Open-in-browser support on macOS.
- **keep** `Modules/RSWeb/Sources/RSWeb/MimeType.swift` (57 lines) — Image/audio/video MIME helpers.
- **keep** `Modules/RSWeb/Sources/RSWeb/NetworkMonitor.swift` (78 lines) — `NWPathMonitor` wrapper for offline state and cellular deferral.
- **keep** `Modules/RSWeb/Sources/RSWeb/String+RSWeb.swift` (38 lines) — `escapedHTML`.
- **keep** `Modules/RSWeb/Sources/RSWeb/URL+RSWeb.swift` (96 lines) — `isHTTPOrHTTPSURL`, browser preparation and query helpers.
- **keep** `Modules/RSWeb/Sources/RSWeb/URLResponse+RSWeb.swift` (45 lines) — Status and header lookup helpers.

## Modules/Secrets

- **delete (PR5)** `Modules/Secrets` (311 lines) — Secrets package (`Package.swift`, `Credentials.swift`, `CredentialsManager.swift`, `SecretKey.swift.gyb`, README, all files); removed in the order protocol requirements -> Account API -> package dependency -> pbxproj links -> scheme pre-actions -> CI -> `.gitignore`/`.swiftlint.yml` -> `updateSecrets.sh` and gyb, leaving `hmacUsingSHA1` dead.

## Modules/SyncDatabase

- **adapt (PR5)** `Modules/SyncDatabase/Sources/SyncDatabase/SyncStatus.swift` (50 lines) — Outbound queue keys `.read`/`.starred`/`.deleted`/`.new` (:14-18); gains `.content` ("the local body changed, re-upload the content record", C0).
- **keep** `Modules/SyncDatabase/Sources/SyncDatabase/Constants.swift` (15 lines) — Column keys.
- **keep** `Modules/SyncDatabase/Sources/SyncDatabase/SyncDatabase.swift` (100 lines) — Pending-status queue API (`insertStatuses`, `selectForProcessing`, pending id lookups, delete and reset).
- **keep** `Modules/SyncDatabase/Sources/SyncDatabase/SyncDatabaseError.swift` (32 lines) — SQLite error wrapper.
- **keep** `Modules/SyncDatabase/Sources/SyncDatabase/SyncStatusTable.swift` (190 lines) — Transactional queue table; inserts are `.orReplace` on (articleID, key) (:141-146), which is why `.content` needs its own key.

## NetNewsWire-CI.xctestplan

- **adapt (PR2)** `NetNewsWire-CI.xctestplan` — CI test plan that skips ScriptingTests (:35-37); drop entries for deleted modules (PR2, PR5) and the moot skip (PR3).

## NetNewsWire-iOS.xctestplan

- **keep** `NetNewsWire-iOS.xctestplan` — Only `NetNewsWire-iOSTests`.

## NetNewsWire.xcodeproj

- **adapt (PR1)** `NetNewsWire.xcodeproj/project.pbxproj` — Project file; removes the Sparkle and plcrashreporter package refs (:1467, :1483, PR1), the Subscribe to Feed target and its exception sets (PR3), the provisioning profile entry (PR4), the Secrets product links (:26-41, :216, :259, :523, :542, :769, :812, :1537-1564, PR5), and the share-extension Frameworks links and `Shared/ShareExtension` exception-set entries (:474-492, PR8); `buildSettings` must never appear because VerifyNoBS (:1065, :1137) fails the Mac build.
- **adapt (PR1)** `NetNewsWire.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — Pins plcrashreporter, Sparkle, Tidemark and Zip; rewritten by Xcode when packages go.
- **adapt (PR5)** `NetNewsWire.xcodeproj/xcshareddata/xcschemes/NetNewsWire-iOS.xcscheme` — iOS scheme; the `updateSecrets.sh` pre-action (:13) goes.
- **adapt (PR1)** `NetNewsWire.xcodeproj/xcshareddata/xcschemes/NetNewsWire.xcscheme` — Mac scheme; fix the nonexistent `CoreTests` testable (:98-107, PR1) and drop the Secrets pre-action (:13, PR5); scheme names stay.
- **keep** `NetNewsWire.xcodeproj/xcshareddata/xcschemes/NetNewsWire iOS Share Extension.xcscheme` — Share extension debugging scheme.

## NetNewsWire.xctestplan

- **adapt (PR2)** `NetNewsWire.xctestplan` — Default plan with 12 test targets; loses the service coverage in AccountTests (PR2) and the `FeedFinderTests` entry (:97-103, PR5).

## README.md

- **adapt (PR12)** `README.md` (95 lines) — Upstream README; rewritten for NetNewsList.

## Shared/AccountStats

- **delete (PR5)** `Shared/AccountStats/AccountStatsViewModel.swift` (120 lines) — View model shared by both AccountStats windows; goes with them.

## Shared/AccountType+Helpers.swift

- **adapt (PR2)** `Shared/AccountType+Helpers.swift` (117 lines) — Log colors and images per `AccountType`; its exhaustive switches shrink with the enum.

## Shared/Activity

- **adapt (PR9)** `Shared/Activity/ActivityManager.swift` (330 lines) — NSUserActivity and Spotlight indexing; delete the feed-selection attributes (:279-293) and `cleanUp(account/folder/feed)` (:142-172), and the `article.feed` keyword (:270) becomes the site.
- **adapt (PR8)** `Shared/Activity/ActivityType.swift` (17 lines) — Activity type enum; `addFeedIntent` is renamed with the intent.

## Shared/AppDelegate+Shared.swift

- **keep** `Shared/AppDelegate+Shared.swift` (38 lines) — `vacuumAllDatabases` helper.

## Shared/AppNotifications.swift

- **adapt (PR6)** `Shared/AppNotifications.swift` (16 lines) — App-level notification names; `UserDidAddFeed` becomes `UserDidAddArticle` or goes, the other two stay.

## Shared/Article Extractor

- **delete (PR7)** `Shared/Article Extractor/ArticleExtractor.swift` (139 lines) — Feedbin Mercury client using `SecretKey.mercuryClientID`/`Secret` (:39-42); replaced in PR5 by a ~30-line stub reporting `.failedToParse` so its ~12 dependents compile, and deleted with them in PR7.
- **adapt (PR7)** `Shared/Article Extractor/ExtractedArticle.swift` (45 lines) — Codable Mercury-shaped DTO (title, author, date, lead image, content, excerpt); kept through PR7 as the extractor output contract, then replaced by the Extraction module's result type once the hooks are gone.

## Shared/Article Rendering

- **adapt (PR7)** `Shared/Article Rendering/ArticleRenderer.swift` (354 lines) — Turns an Article into (style, html, title, baseURL) via `MacroProcessor` and the current theme; drops `extractedArticle` (:39, :108-118, :127-128, PR7) and changes the values of `feed_link`, `feed_link_title` and `avatar_src` (:235, :246-247) to host, `https://host/` and `SiteFaviconCache` (PR9) so no theme needs edits.
- **adapt** `Shared/Article Rendering/ArticleRenderingSpecialCases.swift` (174 lines) — Body-fragment extraction and redirect-script removal stay for arbitrary saved HTML; the Verge and slashdot feed-era cases (:15-32, :79-85, :145-173) can go.
- **adapt (PR7)** `Shared/Article Rendering/WebViewConfiguration.swift` (175 lines) — Builds the WKWebViewConfiguration (non-persistent store :33, scheme handler :37, content rules :111, user scripts :138) and resolves the browser UA (:78-89); `allowsContentJavaScript(for:)` (:53-61) returns hard `false` for stored content (PR7), a copy configures the hidden extraction web view, and `ArticleAssetSchemeHandler` is registered beside the icon scheme (PR11).
- **adapt (PR7)** `Shared/Article Rendering/main.js` (229 lines) — DOMContentLoaded post-processing; drop the Feedbin `data-canonical-src` branch (:66-74), and `convertImgSrc` already leaves `scheme://` sources alone, which PR11's `nnlasset://` rewrite relies on.
- **keep** `Shared/Article Rendering/ArticleTextSize.swift` (50 lines) — Mac text-size enum to CSS class.
- **keep** `Shared/Article Rendering/core.css` (190 lines) — Structural CSS prepended to every theme.
- **keep** `Shared/Article Rendering/newsfoot.js` (173 lines) — Footnote popovers.
- **keep** `Shared/Article Rendering/stylesheet.css` (569 lines) — Default theme CSS.
- **keep** `Shared/Article Rendering/template.html` (47 lines) — Default article template; the `feed_link`/`feed_link_title`/`avatar_src` macro names stay and only their values change in the renderer.

## Shared/ArticleSpecifier.swift

- **keep** `Shared/ArticleSpecifier.swift` (48 lines) — (accountID, articleID) pair for restoration and selection.

## Shared/ArticleStyles

- **keep** `Shared/ArticleStyles/ArticleTheme+Notifications.swift` (15 lines) — Theme import error notification.
- **keep** `Shared/ArticleStyles/ArticleTheme.swift` (108 lines) — Theme = core.css + stylesheet.css + template.html + Info.plist.
- **keep** `Shared/ArticleStyles/ArticleThemeDownloader.swift` (158 lines) — Downloads zipped themes for the theme URL branch (scheme renamed in PR4); keeps the Zip dependency.
- **keep** `Shared/ArticleStyles/ArticleThemePlist.swift` (25 lines) — Theme Info.plist schema.
- **keep** `Shared/ArticleStyles/ArticleThemesManager.swift` (232 lines) — Discovers bundled and user-installed themes.

## Shared/Assets.swift

- **adapt (PR2)** `Shared/Assets.swift` (196 lines) — Shared icon and image constants; the account-service switch (:148-160) shrinks in PR2, `todayFeed` (:95, :124) goes with Today, and the remaining service images go in PR12.

## Shared/Commands

- **delete (PR9)** `Shared/Commands/DeleteCommand.swift` (282 lines) — Undoable Feed/Folder node delete; replaced by `DeleteArticlesCommand` (confirm, not undoable, calls `deleteArticles`).
- **keep** `Shared/Commands/MarkCommandValidationStatus.swift` (22 lines) — Menu validation helper.
- **keep** `Shared/Commands/MarkStatusCommand.swift` (100 lines) — Undoable read/starred marking; Archive is `read`, so only labels change.

## Shared/DefaultAccountNames.xcstrings

- **delete (PR5)** `Shared/DefaultAccountNames.xcstrings` (65 lines) — Localized default account names; go with the account UI.

## Shared/Dinosaurs

- **delete (PR3)** `Shared/Dinosaurs/DinosaursViewModel.swift` (156 lines) — Stale-feed view model shared by the Mac window and the iOS view.

## Shared/Exporters

- **delete (PR3)** `Shared/Exporters/OPMLExporter.swift` (41 lines) — OPML export for the Export sheet; the persisted tree is written by `OPMLFile`, not by this.

## Shared/ExtensionPoints

- **delete (PR3)** `Shared/ExtensionPoints` (176 lines) — `SendToMarsEditCommand` and `SendToMicroBlogCommand` (all files); removed with their use in `SharingServicePickerDelegate` and the MarsEdit entitlement exception.

## Shared/Extensions

- **delete (PR6)** `Shared/Extensions/AddFeedDefaultContainer.swift` (51 lines) — Default account/folder for Add Feed; goes with the pickers.
- **adapt (PR9)** `Shared/Extensions/ArticleUtilities.swift` (201 lines) — `body`, `preferredLink`, `logicalDatePublished` (:87-88, which makes `.date` mean date saved once dates are nil) and `markArticleIDs` (:21-31) stay; gains `siteHost`/`siteHomePageURL`, and `byline()` and `iconImageUrl(feed:)` stop reading `Feed`.
- **adapt (PR11)** `Shared/Extensions/CacheCleaner.swift` (78 lines) — Purges the Favicons, Images and FeedIcons caches every three days (:28-32); must never touch the offline article-image store, which is why that store lives under Application Support.
- **keep** `Shared/Extensions/ArticleStringFormatter.swift` (322 lines) — Title and summary truncation, `sanitizedTitle` and date strings for the renderer and timeline.
- **keep** `Shared/Extensions/SmallIconProvider.swift` (39 lines) — `smallIcon` for Account, Feed and Folder, needed by `PseudoFeed`.

## Shared/HelpURL.swift

- **adapt (PR12)** `Shared/HelpURL.swift` (28 lines) — netnewswire.com help, website, Discourse and privacy URLs; repointed with the Help menu.

## Shared/IconImageCache.swift

- **adapt (PR9)** `Shared/IconImageCache.swift` (186 lines) — Main-actor icon cache keyed by smart feed, feed or author; `imageForArticle` (:92-98) consults `SiteFaviconCache` instead of `article.feed`, `prefetchImagesForArticles` (:61-80) prefetches by host, and `isNetNewsWireBrandedFeed` (:112-133) goes.

## Shared/Importers

- **delete (PR3)** `Shared/Importers/DefaultFeeds.opml` — Default subscriptions.
- **delete (PR3)** `Shared/Importers/DefaultFeedsImporter.swift` (19 lines) — First-run import of `DefaultFeeds.opml` (Mac/AppDelegate.swift:202, iOS/AppDelegate.swift:76).

## Shared/Localizable.xcstrings

- **adapt (PR12)** `Shared/Localizable.xcstrings` (1273 lines) — Shared string catalog; stale entries purged.

## Shared/Resources

- **keep** `Shared/Resources/ContentRules.json` — WKContentRuleList blocking ad and tracker hosts; kept for saved pages and the live-page retry.

## Shared/Settings

- **delete (PR5)** `Shared/Settings/AddCloudKitAccount.swift` (70 lines) — iCloud-Drive-missing error and open-settings recovery for the add-account sheets; deleted with the account UI, and its "sign in to iCloud" message reappears as the single account's error state.

## Shared/ShareExtension

- **delete (PR8)** `Shared/ShareExtension/ExtensionContainers.swift` (115 lines) — Codable account/folder models for the extension pickers; nothing to pick.
- **delete (PR8)** `Shared/ShareExtension/ExtensionContainersFile.swift` (114 lines) — Writes the accounts/folders list for extensions; goes with `ExtensionContainers`.
- **delete (PR8)** `Shared/ShareExtension/ShareDefaultContainer.swift` (49 lines) — Remembered destination container; goes with the pickers.
- **adapt (PR8)** `Shared/ShareExtension` (491 lines) — App-group request-file handoff shared by both share extensions and the intent; simplified to a URL-only request, with the exception sets `84D35E0A/0B/0C/0F` edited to match.
- **adapt (PR8)** `Shared/ShareExtension/ExtensionFeedAddRequest.swift` (24 lines) — Codable `{name?, feedURL, destinationContainerID}` payload; becomes `SavedArticleRequest {url, title?, body?}`.
- **adapt (PR4)** `Shared/ShareExtension/ExtensionFeedAddRequestFile.swift` (189 lines) — App-group plist queue with NSFilePresenter; the force-unwraps in `filePath` (:19-23) become a guard that logs and disables ingress (PR4), `processRequest` (:163-190) calls the save path instead of `createFeed` (PR8), and one file per request under `<group>/Inbox/` follows when bodies start flowing.
- **keep** `Shared/ShareExtension/SafariExt.js` (12 lines) — Share-extension preprocessing script returning `document.URL`; optional later home for Readability capture.

## Shared/SmartFeeds

- **adapt (PR9)** `Shared/SmartFeeds` (514 lines) — The sidebar model: `PseudoFeed`, `SmartFeed`, `SmartFeedsController` and the delegates; gains `ArchiveFeedDelegate` (`FetchType.read`) and `AllFeedDelegate` (`.feed(readingListFeed)`), ~30 lines each.
- **adapt (PR9)** `Shared/SmartFeeds/SmartFeedsController.swift` (46 lines) — Singleton holding `[todayFeed, unreadFeed, starredFeed]` (:25, :31); becomes Inbox, Starred, Archive, All, with `find(by:)` (:28-36) kept for restoration and the icon cache.
- **adapt (PR9)** `Shared/SmartFeeds/UnreadFeed.swift` (85 lines) — All Unread pseudo feed with forced `.alwaysRead` filter; relabeled Inbox with the class name kept because restoration persists `String(describing:)`.
- **keep** `Shared/SmartFeeds/PseudoFeed.swift` (31 lines) — Marker protocol both UIs type-check against.
- **keep** `Shared/SmartFeeds/SearchFeedDelegate.swift` (40 lines) — Global search pseudo feed over FTS.
- **keep** `Shared/SmartFeeds/SearchTimelineFeedDelegate.swift` (40 lines) — iOS timeline-scoped search.
- **keep** `Shared/SmartFeeds/SmartFeed.swift` (136 lines) — Delegate-driven pseudo feed with cached unread count; iterates `activeAccounts` (:89-100), fine with one account.
- **keep** `Shared/SmartFeeds/SmartFeedDelegate.swift` (38 lines) — Delegate protocol that the two new lists implement.
- **keep** `Shared/SmartFeeds/SmartFeedPasteboardWriter.swift` (38 lines) — Pasteboard writer required by `PasteboardWriterOwner` on macOS.
- **keep** `Shared/SmartFeeds/StarredFeedDelegate.swift` (30 lines) — Starred list, unchanged.
- **decide** `Shared/SmartFeeds/TodayFeedDelegate.swift` (30 lines) — `FetchType.today` list; deleted with Today in PR9 unless kept as Saved Today, which nil `datePublished` gives for free (ArticlesTable.swift:710).

## Shared/Timeline

- **adapt (PR6)** `Shared/Timeline/ArticleSortParameters.swift` (82 lines) — String-backed, persisted `ArticleSortKey` (:12-17); `.date` is relabeled "Date Saved" with no new case (PR6) and `.feed` becomes site (PR9).
- **adapt (PR9)** `Shared/Timeline/ArticleSorter.swift` (120 lines) — Sort by date, feed, title, unread or starred; the `.feed` sort and `groupByFeed` (:117-119) use the site name.
- **keep** `Shared/Timeline` (620 lines) — Article array helpers, sort parameters and the fetch-request queue.
- **keep** `Shared/Timeline/ArticleArray.swift` (139 lines) — Next-unread, mark-all and above/below helpers.
- **keep** `Shared/Timeline/FetchRequestOperation.swift` (220 lines) — Runs fetchers on the main actor with an `#if os(macOS)` split (:26, :114) and no `FetchType` switch, so `.read` needs no change here.
- **keep** `Shared/Timeline/FetchRequestQueue.swift` (59 lines) — Serial fetch queue.

## Shared/Timer

- **delete (PR5)** `Shared/Timer/AccountRefreshTimer.swift` (107 lines) — Periodic feed-refresh timer (exception set `84D35E0B`); goes with `refreshTimer` in the Mac AppDelegate.
- **delete (PR5)** `Shared/Timer/RefreshInterval.swift` (55 lines) — Refresh interval enum (exception set `84D35E0F`); goes with `AppDefaults.refreshInterval` and the General popup.
- **keep** `Shared/Timer/ArticleStatusSyncTimer.swift` (106 lines) — Fires `syncArticleStatusAll` every 120 s, backing off to 1800 s when idle (:15-16) and reset by `.AccountDidQueueArticleStatuses`, which is why the save path must post that notification.

## Shared/Tree

- **delete (PR6)** `Shared/Tree/FolderTreeControllerDelegate.swift` (53 lines) — Account/folder tree for the Add Feed folder popup.
- **adapt (PR9)** `Shared/Tree/SidebarTreeControllerDelegate.swift` (152 lines) — Builds the sidebar tree; `childNodesForRootNode` (:43) returns only the smart-feeds node (:46-49) and the account and folder branches (:63-128) go.

## Shared/UserInfoKey.swift

- **adapt (PR7)** `Shared/UserInfoKey.swift` (31 lines) — Notification and restoration keys; the extractor keys (:27) go in PR7 and `feed`/`feedIdentifier` can be pruned later.

## Shared/UserNotifications

- **delete (PR3)** `Shared/UserNotifications/UserNotificationManager.swift` (113 lines) — Local notifications for new articles in feeds with notifications enabled; removed with `start()` and the action-identifier switches in both AppDelegates.

## Shared/Widget

- **adapt (PR4)** `Shared/Widget` (346 lines) — Widget data encoder, decoder and deep links; the `com.ranchero.NetNewsWire.*Widget` kinds and `nnw://` scheme are renamed in PR4, Today plumbing goes with Today (PR9/PR12) and `feedTitle` becomes the site (PR12).
- **adapt (PR12)** `Shared/Widget/WidgetData.swift` (29 lines) — Codable widget payload; `totalTodayCount`, `totalTodayUnreadCount` and `todayArticles` (:13-18) go with Today and `feedTitle` becomes `siteTitle`.
- **adapt (PR12)** `Shared/Widget/WidgetDataEncoder.swift` (235 lines) — Fetches unread, starred and today articles through the smart feeds and writes `widget-data.json` plus favicons to the app group; the `todayArticles` change detection (:101-113, :137) goes with Today, `article.iconImage()` (:218) goes through `SiteFaviconCache` and `feedTitle` (:223) becomes the host.
- **adapt (PR4)** `Shared/Widget/WidgetDeepLinks.swift` (46 lines) — `nnw://showunread|showtoday|showstarred` links (:15-31); scheme renamed, `.today`/`.todayArticle` (:29-31) go with Today.
- **keep** `Shared/Widget/WidgetDataDecoder.swift` (36 lines) — Reads `widget-data.json` from the app group.

## Technotes

- **delete** `Technotes/DevelopmentAlphaBeta.md` (28 lines) — Upstream release-stage definitions.
- **delete (PR12)** `Technotes/HowToDoMacSparkleRelease.markdown` (76 lines) — Upstream Sparkle release procedure.
- **delete (PR12)** `Technotes/HowToDoiOSAppStoreRelease.markdown` (20 lines) — Upstream App Store release procedure.
- **delete (PR12)** `Technotes/HowToDoiOSTestFlightRelease.markdown` (76 lines) — Upstream TestFlight release procedure.
- **adapt (PR12)** `Technotes/Accounts.markdown` (54 lines) — Describes the multi-account model; rewritten for the single iCloud account.
- **adapt (PR12)** `Technotes/DatabaseCleanup.md` (32 lines) — Describes a per-feed keep-20 cleanup the code no longer implements; folded into the retention section of the new `Technotes/NetNewsList/ReadingList.md` ("nothing is auto-deleted; only orphan statuses are swept").
- **adapt (PR12)** `Technotes/Dependencies.markdown` (17 lines) — Lists FMDB, PLCrashReporter, Sparkle and Zip; updated after the removals.
- **adapt (PR12)** `Technotes/RetentionPolicy.markdown` (72 lines) — Documents feed-based retention (and is already inaccurate about starred articles in unsubscribed feeds); rewritten for keep-forever.
- **adapt (PR12)** `Technotes/Widgets.md` (51 lines) — Widget data-flow note whose model is out of date; updated with the Inbox/Starred widget.
- **keep** `Technotes/ArticlesAndStatuses.markdown` (37 lines) — Why articles and statuses are separate tables; still true.
- **keep** `Technotes/FindingYourDevelopmentTeamID.md` (13 lines) — How to find the Team ID.
- **keep** `Technotes/Themes.md` (35 lines) — Theme format reference.

## Tests

- **delete (PR3)** `Tests/NetNewsWireTests/ScriptingTests` (165 lines) — AppleScript tests and `.applescript` fixtures.
- **keep** `Tests/NetNewsWire-iOSTests` (81 lines) — ActivityItemSource and MultilineUILabelSizer tests.
- **keep** `Tests/NetNewsWireTests` (1682 lines) — Rendering, sorter, string formatter, sanitized title, theme unzip, body-fragment and sharing tests over the reading UX that stays.

## Themes

- **keep** `Themes` — The eight bundled `.nnwtheme` bundles; all use `feed_link`, `feed_link_title` and `avatar_src`, whose values (not names) change in `ArticleRenderer`, so no theme edits.

## Widget

- **adapt (PR4)** `Widget` (658 lines) — WidgetKit extension kept for Inbox and Starred plus the lock-screen summary; kinds, bundle id and entitlements change in PR4 and the Today widget goes with Today.
- **adapt (PR4)** `Widget/Info.plist` (37 lines) — Widget extension plist with the AppGroup value.
- **adapt (PR4)** `Widget/NetNewsWire_iOS_WidgetExtension.entitlements` (14 lines) — App group renamed and the keychain access group (:9-12) removed with the other three iOS entitlements files.
- **adapt (PR12)** `Widget/Resources/widget-sample.json` — Placeholder data; Today entries removed and titles updated.
- **adapt (PR12)** `Widget/Shared Views/ArticleItemView.swift` (84 lines) — Row with icon, title, `feedTitle` and date; `feedTitle` becomes the site.
- **adapt (PR12)** `Widget/Widget Views/LockScreenSummaryWidget.swift` (61 lines) — Accessory counts; `totalTodayCount` (:26-29) goes with Today.
- **adapt (PR4)** `Widget/Widget Views/UnreadWidget.swift` (98 lines) — Unread list with deep links; relabeled Inbox, deep-link scheme renamed.
- **adapt (PR4)** `Widget/WidgetBundle.swift` (100 lines) — Unread, Today, Starred and lock-screen widgets; kinds (:15, :34, :53, :72) renamed and the Today widget (:34-51) goes with Today.
- **keep** `Widget/Shared Views/SizeCategories.swift` (23 lines) — Size helpers.
- **keep** `Widget/TimelineProvider.swift` (73 lines) — Reads `WidgetDataDecoder` with a 30-minute fallback.
- **keep** `Widget/Widget Views/StarredWidget.swift` (99 lines) — Starred list view.
- **keep** `Widget/Widget Views/WidgetLayout.swift` (19 lines) — Layout constants.
- **decide** `Widget/Widget Views/TodayWidget.swift` (101 lines) — Today list widget; deleted with Today (PR9/PR12) unless Today is kept as Saved Today.

## buildscripts

- **delete** `buildscripts/certs` — Ranchero's encrypted distribution certificates.
- **delete** `buildscripts/ci-build.sh` (45 lines) — Decrypts Ranchero's certs and profiles for a signed CI build; unusable by the fork.
- **delete (PR1)** `buildscripts/crash-logs.sh` (5 lines) — Crash log helper; goes with the crash reporter.
- **delete (PR5)** `buildscripts/gyb` — python3 shim for `gyb.py`; goes with Secrets.
- **delete (PR5)** `buildscripts/gyb.py` (1271 lines) — Vendored GYB; goes with Secrets.
- **delete** `buildscripts/old_buildnnw` — Legacy release packager referencing a nonexistent workspace.
- **delete** `buildscripts/profile` — Ranchero's encrypted provisioning profiles.
- **delete (PR5)** `buildscripts/updateSecrets.sh` (11 lines) — Runs gyb to emit `SecretKey.swift`; goes with Secrets.
- **adapt (PR1)** `buildscripts/build_and_test.sh` (37 lines) — Builds both schemes and tests only the Mac scheme (:30-35); made to run the iOS test plan too, scheme names kept.
- **adapt (PR1)** `buildscripts/quiet_build_and_test.sh` (37 lines) — Quiet variant; same change.
- **keep** `buildscripts/VerifyNoBS.swift` (155 lines) — Run-script guard that fails the Mac build if `buildSettings` appear in the pbxproj; the reason to diff the pbxproj after every Xcode UI action.
- **keep** `buildscripts/build-local-test.sh` (51 lines) — Universal debug build copied to the Desktop.
- **keep** `buildscripts/fail_on_warnings.sh` (34 lines) — Greps the build log for first-party warnings.

## iOS/Account

- **delete (PR5)** `iOS/Account` (644 lines) — Account sheets (`AccountIconHeader`, `AccountNotificationInspectorView`, `AccountSheetFooter`, `CloudKitAccountView`, `CredentialsAccountView`, `LocalAccountView`, all files); `CredentialsAccountView.swift` (329) already falls out in PR2 and the rest goes when the iCloud account is created automatically.

## iOS/AccountStats

- **delete (PR10)** `iOS/AccountStats/AccountStatsView.swift` (181 lines) — Database size and feed/folder/article counts view.

## iOS/Add

- **delete (PR6)** `iOS/Add/AddFeedContainerPickerView.swift` (87 lines) — Account/folder picker.
- **delete (PR6)** `iOS/Add/AddFolderView.swift` (134 lines) — Create-folder sheet.
- **adapt (PR6)** `iOS/Add/AddFeedView.swift` (152 lines) — SwiftUI Add Feed sheet with pasteboard prefill (:113-114); becomes `AddArticleView` (URL plus optional title) calling `saveArticle`, without the container picker.

## iOS/AppDefaults.swift

- **adapt (PR4)** `iOS/AppDefaults.swift` (634 lines) — UserDefaults wrapper and `StateRestorationInfo` (:499-634); `isDeveloperBuild` goes (PR4), the extractor restoration keys (:72, :311-316, :508-541, :632) go (PR7), the file is dropped from the share-extension exception set `84A6D040` (PR8), and `refreshClearsReadArticles`, the feed/folder hide-read maps and the add-feed keys go (PR10).

## iOS/AppDelegate.swift

- **adapt (PR3)** `iOS/AppDelegate.swift` (513 lines) — Lifecycle, badge, push (:91, :114-120) and the `isSyncArticleStatusRunning`/`isWaitingForSyncTasks` plumbing (:47-48, :276-350) stay; `DefaultFeedsImporter` (:74-77) and `UserNotificationManager` (:96, :228-230) go in PR3, the `SKIP_APP_GROUP_ACCESS` guards (:101-104, :174-176, :187-189), quick-action types (:254-266) and BGTask id (:393, :406) change in PR4, and the renamed `BGAppRefreshTask` (:393-417) drains the request queue in PR8.

## iOS/AppIntents

- **adapt (PR8)** `iOS/AppIntents/AddFeedAppIntent.swift` (122 lines) — App Intent enqueuing an `ExtensionFeedAddRequest` with `openAppWhenRun = false` (:19); moves to `Shared/AppIntents/SaveArticleIntent.swift` in both targets, drops the account/folder parameters (:24-27) and options providers (:90-122) and gains an optional `body`.
- **adapt (PR8)** `iOS/AppIntents/NetNewsWireAppShortcuts.swift` (24 lines) — `AppShortcutsProvider` phrases (:11-16); moves to `Shared/AppIntents/NetNewsListAppShortcuts.swift` with "Save to NetNewsList" phrases.

## iOS/Article

- **adapt (PR9)** `iOS/Article/ArticleIconSchemeHandler.swift` (56 lines) — `nnwImageIcon` handler resolving the article through `SceneCoordinator`; serves the `SiteFaviconCache` icon (PR9) and is the template for `ArticleAssetSchemeHandler` (PR11).
- **adapt (PR4)** `iOS/Article/ArticleViewController.swift` (612 lines) — Page-view container with toolbar; the developer-build gate (:286) goes in PR4 and the extractor button and state (:43, :143-144, :269, :347-348, :375-376, :496-500, :601) become Show Original in PR7.
- **adapt (PR10)** `iOS/Article/ContextMenuPreviewViewController.swift` (64 lines) — Context-menu preview; `article.feed?.nameForDisplay` becomes the host.
- **adapt (PR7)** `iOS/Article/WebViewController.swift` (1034 lines) — Per-article web view controller; the extractor code (:53-71, :179-207, :287-322, :364-391, :727-741) and the `readerViewAlwaysEnabled` read (:179) go and `allowsContentJavaScript` (:452) is hard `false` for stored content (PR7), the `showFeedInspector` message (:28, :550-553) goes (PR10), and tap-to-zoom (:759-776) reads the asset store for `nnlasset` URLs (PR11).
- **adapt (PR7)** `iOS/Article/ArticleExtractorButton.swift` (98 lines) — Reader View button with activity indicator; becomes the Show Original toggle.
- **keep** `iOS/Article/ArticleSearchBar.swift` (180 lines) — Find-in-article UI.
- **keep** `iOS/Article/FindInArticleActivity.swift` (40 lines) — Find activity.
- **keep** `iOS/Article/ImageScrollView.swift` (360 lines) — Zoom and pan view for the image viewer.
- **keep** `iOS/Article/ImageTransition.swift` (147 lines) — Inline-image to viewer transition.
- **keep** `iOS/Article/ImageViewController.swift` (111 lines) — Full-screen image viewer fed by `WebViewController`'s download.
- **keep** `iOS/Article/OpenInSafariActivity.swift` (51 lines) — Open-in-Safari activity.
- **keep** `iOS/Article/PreloadedWebView.swift` (72 lines) — WKWebView subclass preloading `blank.html`.
- **keep** `iOS/Article/WebViewFullscreenKeeper.swift` (37 lines) — Retains web views during element fullscreen.
- **keep** `iOS/Article/WebViewProvider.swift` (99 lines) — Pool of three preloaded web views.
- **keep** `iOS/Article/WrapperScriptMessageHandler.swift` (25 lines) — Weak `WKScriptMessageHandler` wrapper.

## iOS/ArticleActivityItemSource.swift

- **keep** `iOS/ArticleActivityItemSource.swift` (33 lines) — Share item source.

## iOS/Base.lproj

- **adapt (PR10)** `iOS/Base.lproj/Main.storyboard` — Main storyboard; the Folder cell and Container header prototypes go, the rest stays.
- **keep** `iOS/Base.lproj/LaunchScreenPad.storyboard` — Launch screen; rebrand only.
- **keep** `iOS/Base.lproj/LaunchScreenPhone.storyboard` — Launch screen; rebrand only.

## iOS/CurrentActivity

- **keep** `iOS/CurrentActivity/CurrentActivityView.swift` (120 lines) — SwiftUI list of running ActivityLog activities; shows sync and extraction.

## iOS/ErrorHandler.swift

- **keep** `iOS/ErrorHandler.swift` (32 lines) — Present and log errors.

## iOS/HidingReadArticlesState.swift

- **adapt (PR10)** `iOS/HidingReadArticlesState.swift` (150 lines) — Per-item hide-read state keyed by `SidebarItemIdentifier`; keeps only the `.smartFeed` branch (:43-47, :81-90, :147-149).

## iOS/IconView.swift

- **keep** `iOS/IconView.swift` (121 lines) — Icon rendering view.

## iOS/Inspector

- **delete (PR5)** `iOS/Inspector/AccountInspectorViewController.swift` (239 lines) — Account name/active/delete/credentials screen with the C7 sync-content switch (:36, :62-64, :213); deleted with its storyboard scene, the switch is not moved.
- **delete (PR10)** `iOS/Inspector/FeedInspectorViewController.swift` (251 lines) — Feed name, notifications, always-reader-view and URL inspector; the last iOS reader of `Feed.readerViewAlwaysEnabled`.
- **delete (PR10)** `iOS/Inspector/Inspector.storyboard` — Account and feed inspector scenes (the account scene goes in PR5).
- **delete (PR10)** `iOS/Inspector/InspectorIconHeaderView.swift` (34 lines) — Header used only by the feed inspector.

## iOS/KeyboardManager.swift

- **adapt (PR10)** `iOS/KeyboardManager.swift` (222 lines) — Builds key commands from the shared shortcut plists plus hard-coded commands; drops `addNewFolder:`, `goToToday:` (:144-145), `toggleReadFeedsFilter:`, `showFeedInspector:` and the subscription-walking entries, `refresh:` becomes `sync:` and `addNewFeed:` becomes `addNewArticle:`.

## iOS/MainFeed

- **delete (PR10)** `iOS/MainFeed/Collection View Cells/MainFeedCollectionHeaderReusableView.swift` (138 lines) — Collapsible section header; one fixed section needs none.
- **delete (PR10)** `iOS/MainFeed/Collection View Cells/MainFeedCollectionViewFolderCell.swift` (168 lines) — Folder row with disclosure.
- **delete (PR10)** `iOS/MainFeed/MainFeedCollectionViewController+Drag.swift` (40 lines) — Feed drag source.
- **delete (PR10)** `iOS/MainFeed/MainFeedCollectionViewController+Drop.swift` (170 lines) — Feed drop into folders; accepts no external URLs.
- **adapt (PR10)** `iOS/MainFeed/MainFeedCollectionViewController.swift` (1513 lines) — Sidebar collection view with diffable data source, cells, headers, context menus and refresh control; becomes a single-section list of the four smart feeds, losing the folder cell branch, account headers, feed context menus (:1088-1382 except `makePseudoFeedContextMenu`), rename/delete (:1384-1492), `refreshAccounts` (:939-947) and the add menu (:912-983).
- **adapt (PR5)** `iOS/MainFeed/RefreshProgressView.swift` (161 lines) — Toolbar progress bar bound to `CombinedRefreshProgress` (:28, :77, :92, :101); re-sourced from `syncProgress` or deleted with the refresher (open question 10).
- **keep** `iOS/MainFeed/Collection View Cells/MainFeedCollectionViewCell.swift` (116 lines) — Sidebar row with title, icon and unread badge; indentation can go.
- **keep** `iOS/MainFeed/Collection View Cells/MainFeedRowIdentifier.swift` (23 lines) — NSCopying identifier for context menus; still needed by `makePseudoFeedContextMenu` (MainFeedCollectionViewController.swift:1164).

## iOS/MainTimeline

- **adapt (PR10)** `iOS/MainTimeline/Cell/MainTimelineCell.swift` (273 lines) — Manual-layout timeline cell; the feed-name slot shows the host and favicon from `SiteFaviconCache`, and a Saving/Failed glyph is added (PR7).
- **adapt (PR10)** `iOS/MainTimeline/Cell/MainTimelineCellData.swift` (91 lines) — Cell view model built from Article and `ShowFeedName`; the feed name and byline come from the site and stored byline.
- **adapt (PR10)** `iOS/MainTimeline/MainTimelineModernViewController.swift` (1459 lines) — Timeline list with swipe read/star, context menus, Here/All search scopes and toolbar; the `article.feed` read (:900), Go to Feed and Mark All in Feed (~:1300-1379) and the `showFeedInspector` taps (:24, :112, :128, :452-455) go, pull-to-refresh (:420-428) becomes Sync, and swipe/context Delete and Retry are added.
- **keep** `iOS/MainTimeline/Cell/MainTimelineCellLayout.swift` (251 lines) — Cell layout math.
- **keep** `iOS/MainTimeline/Cell/MultilineUILabelSizer.swift` (153 lines) — Text sizing cache.
- **keep** `iOS/MainTimeline/Cell/SingleLineUILabelSizer.swift` (51 lines) — Text sizing cache.
- **keep** `iOS/MainTimeline/Cell/StringSize+Extensions.swift` (23 lines) — Sizing helpers.
- **keep** `iOS/MainTimeline/MainTimelineDataSource.swift` (24 lines) — Diffable data source subclass.
- **keep** `iOS/MainTimeline/MarkAsReadAlertController.swift` (83 lines) — Confirm mark-all-as-read (relabeled Archive All).

## iOS/NetNewsWire-iOS-Bridging-Header.h

- **keep** `iOS/NetNewsWire-iOS-Bridging-Header.h` (5 lines) — Imports `SFSafariViewController+Extras.h`.

## iOS/Resources

- **delete (PR4)** `iOS/Resources/NetNewsWire-dev.entitlements` (14 lines) — Developer entitlements with only app group and keychain group and no iCloud; both `-dev` files go.
- **adapt (PR12)** `iOS/Resources/Assets.xcassets` — iOS asset catalog; the third-party account imagesets go, cloudkit stays.
- **adapt (PR4)** `iOS/Resources/Info.plist` (225 lines) — iOS Info.plist; the BGTask id (:11-14), URL schemes (:36-50, `netnewslist` replacing `feed`/`feeds`/`netnewswire`), `CFBundleURLName` values (:34-35, :45-46) and UserAgent strings (:220-223) change, while the remote-notification background mode, AppGroup and theme UTI stay.
- **adapt (PR4)** `iOS/Resources/NetNewsWire.entitlements` (28 lines) — Full iOS entitlements; container `iCloud.$(ORG).NetNewsList`, renamed app group, `aps-environment = development`, no hardcoded `icloud-container-environment` (:5-8), keychain access group (:23-26) removed, kvstore later (PR5).
- **adapt (PR10)** `iOS/Resources/main_ios.js` (520 lines) — Image viewer, media source posting and find-in-article; drops `showFeedInspectorSetup` (:138-153, :157).
- **keep** `iOS/Resources/blank.html` (11 lines) — Preload page.
- **keep** `iOS/Resources/page.html` (19 lines) — iOS page wrapper with viewport meta and `window.scrollTo(0, [[windowScrollY]])`.

## iOS/RootSplitViewController.swift

- **adapt (PR10)** `iOS/RootSplitViewController.swift` (197 lines) — Split view controller with keyboard-shortcut targets and widget deep-link handling; drops `addNewFolder`, previous/next subscription, `refresh` and `toggleReadFeedsFilter`, keeps the deep links (renamed scheme, Today link removed).

## iOS/SceneCoordinator.swift

- **adapt (PR8)** `iOS/SceneCoordinator.swift` (2689 lines) — Navigation and selection hub; gains `showSaveArticle(urlString:)` (PR8), then in PR10 loses tree expand/collapse (~:950-1031, :2098-2128), filter exceptions (~:1888-1934), `discloseFeed` (~:1432-1478), inspectors (~:1512-1544), `showAddFolder`, folder/account branches, next-unread-feed walking and the refresh subtitle logic (:722-809, `CombinedRefreshProgress` at :397, :723), while `rebuildBackingStores`, `exceptionArticleFetcher` (~:2461-2464), search, mark commands, restoration, widget deep links and the `userInfo[feeds]` guard (:663-665) stay.

## iOS/SceneDelegate.swift

- **adapt (PR4)** `iOS/SceneDelegate.swift` (250 lines) — Scene setup, URL handling, quick actions and restoration; the `feed:`/`feeds:` branch (:130-137) goes and the widget deep-link branches (:139-193) stay with the renamed scheme (PR4), and `netnewslist://add?url=&title=` is inserted before the theme guard in `scene(_:openURLContexts:)` (:202-213, PR8).

## iOS/Settings

- **delete (PR5)** `iOS/Settings/AddAccountView.swift` (193 lines) — Account-type picker including Feedly OAuth (edited in PR2, deleted in PR5).
- **delete (PR5)** `iOS/Settings/CloudKitStatsView.swift` (338 lines) — iOS iCloud Stats and Clean Up view; goes with C6.
- **delete (PR3)** `iOS/Settings/DinosaurRowView.swift` (57 lines) — Stale-feed row.
- **delete (PR3)** `iOS/Settings/DinosaursView.swift` (158 lines) — Stale-feed list.
- **delete (PR5)** `iOS/Settings/SettingsComboTableViewCell.swift` (29 lines) — Account row cell used only by the accounts list.
- **adapt (PR12)** `iOS/Settings/AboutContributor.swift` (67 lines) — Contributors; re-credited.
- **adapt (PR12)** `iOS/Settings/AboutCreditView.swift` (46 lines) — Credits; re-credited.
- **adapt (PR12)** `iOS/Settings/AboutView.swift` (73 lines) — About; rebranded.
- **adapt (PR3)** `iOS/Settings/Settings.storyboard` — Static cells for the settings table plus theme, palette and timeline customizer scenes; the Feeds rows go (PR3), the Accounts and troubleshooting rows (PR5) and Notifications (PR10), with `Section`/`Row` renumbering each time.
- **adapt (PR3)** `iOS/Settings/SettingsViewController.swift` (601 lines) — Static-table settings; the Feeds/OPML section (:240-259, :431-576) and NetNewsWire News row (:178, :456-465) go in PR3, the Accounts section and the `accountStats`/`dinosaurs`/`cloudKitZoneStats` troubleshooting rows (:32-37) go in PR5 with Reset iCloud Sync added, the JavaScript switch (:134, :408) is relabeled in PR7, and Notifications, `refreshClearsReadArticles` and `groupByFeed -> groupBySite` change in PR10.
- **keep** `iOS/Settings/ActivityLogView.swift` (138 lines) — SwiftUI activity log.
- **keep** `iOS/Settings/ArticleThemeImporter.swift` (99 lines) — Theme import.
- **keep** `iOS/Settings/ArticleThemesTableViewController.swift` (134 lines) — Theme list.
- **keep** `iOS/Settings/ColorPaletteTableViewController.swift` (42 lines) — Light/dark/auto.
- **keep** `iOS/Settings/ErrorLogView.swift` (147 lines) — SwiftUI error log.
- **keep** `iOS/Settings/TickMarkSlider.swift` (90 lines) — Slider.
- **keep** `iOS/Settings/TimelineCustomizerCell.swift` (69 lines) — Preview cell.
- **keep** `iOS/Settings/TimelineCustomizerCollectionViewController.swift` (190 lines) — Icon size and line count preview.
- **keep** `iOS/Settings/TimelineHeaderView.swift` (34 lines) — Header.

## iOS/ShareExtension

- **delete (PR8)** `iOS/ShareExtension/ShareFolderPickerCell.swift` (14 lines) — Folder picker cell; goes with `ShareFolderPickerAccountCell.xib` and `ShareFolderPickerFolderCell.xib` (49 lines each).
- **delete (PR8)** `iOS/ShareExtension/ShareFolderPickerController.swift` (77 lines) — Account/folder picker (exception sets `84A6D03F`/`84A6D040`).
- **adapt (PR4)** `iOS/ShareExtension/NetNewsWire_iOS_ShareExtension.entitlements` (14 lines) — `$(APP_GROUP_ID)` plus keychain group (:9-12); group renamed, keychain group removed, no CloudKit entitlement added.
- **adapt (PR8)** `iOS/ShareExtension/ShareViewController.swift` (233 lines) — iOS share sheet; keeps `resolveURL()` (:203-232) and the queue write (:80-93), drops the folder section, picker delegate and `ExtensionContainers` usage (:26-28, :64-68, :95-102, :145-157, :162-170).
- **keep** `iOS/ShareExtension/Info.plist` (49 lines) — Activation rule accepting one web URL or text, `SafariExt` preprocessing and `$(APP_GROUP_ID)`; already the right shape.

## iOS/TitleActivityItemSource.swift

- **keep** `iOS/TitleActivityItemSource.swift` (39 lines) — Share item source.

## iOS/UIKit Extensions

- **adapt (PR2)** `iOS/UIKit Extensions/UIViewController+Extras.swift` (84 lines) — Error presentation that offers `CredentialsAccountView` for `AccountError.isCredentialsError` (:17, :42); those branches go with the sync services.

## scripts

- **adapt (PR1)** `scripts` — Developer scripts; the crash symbolication scripts (`symbolicate_*`, `MacCrashLogs`, `README_SYMBOLICATION.md`) go with the crash reporter, while `cleanPrefsAndData` (bundle-id paths updated in PR4), `delete-build-folders-from-modules` and `check_localization_comments.py` stay.

## setup.sh

- **adapt (PR4)** `setup.sh` (42 lines) — Writes `../SharedXcodeSettings/DeveloperSettings.xcconfig`; `>>` becomes `>` (:31) so re-running does not append duplicates and `DEVELOPER_ENTITLEMENTS = -dev` (:38) is no longer written.

## xcconfig

- **delete (PR3)** `xcconfig/NetNewsWire_safariextension_target.xcconfig` (5 lines) — Safari extension bundle id; goes with the target.
- **adapt (PR4)** `xcconfig/NetNewsWireTests_target.xcconfig` (9 lines) — Mac tests; the only hardcoded `com.ranchero` bundle id (:7) becomes `$(ORGANIZATION_IDENTIFIER)`.
- **adapt (PR4)** `xcconfig/NetNewsWire_iOSapp_target.xcconfig` (16 lines) — iOS app; bundle id (:8) becomes `$(ORG).NetNewsList.iOS$(BUNDLE_ID_SUFFIX)` and the entitlements switch (:7) collapses to one file.
- **adapt (PR4)** `xcconfig/NetNewsWire_iOSshareextension_target.xcconfig` (4 lines) — iOS share extension bundle id (:4) renamed.
- **adapt (PR4)** `xcconfig/NetNewsWire_iOSwidgetextension_target.xcconfig` (6 lines) — Widget bundle id (:4) renamed to `.iOS.Widget`.
- **adapt (PR4)** `xcconfig/NetNewsWire_macapp_target.xcconfig` (7 lines) — Mac product name and bundle id (:5) renamed to `$(ORG).NetNewsList`; `PRODUCT_MODULE_NAME = NetNewsWire` stays.
- **adapt (PR4)** `xcconfig/NetNewsWire_project_debug.xcconfig` (21 lines) — Debug configuration; `SKIP_APP_GROUP_ACCESS` (:15, :18, :21) is removed so Debug builds drain the request queue.
- **adapt (PR4)** `xcconfig/NetNewsWire_shareextension_target.xcconfig` (6 lines) — Mac share extension bundle id (:5) renamed.
- **adapt (PR4)** `xcconfig/common/NetNewsWire_codesigning_common.xcconfig` (39 lines) — Root of identity: `ORGANIZATION_IDENTIFIER`, `DEVELOPMENT_TEAM`, `DEVELOPER_ENTITLEMENTS` defaults (:7-8) and the include of `DeveloperSettings.xcconfig` (:39); defaults updated, entitlements switch dropped.
- **adapt (PR4)** `xcconfig/common/NetNewsWire_ios_target_common.xcconfig` (10 lines) — `APP_GROUP_ID` (:6) becomes `group.$(ORG).NetNewsList.iOS$(APP_GROUP_SUFFIX)`.
- **adapt (PR4)** `xcconfig/common/NetNewsWire_mac_target_common.xcconfig` (11 lines) — `APP_GROUP_ID` (:6) becomes the Team-ID-prefixed `$(TeamIdentifierPrefix)$(ORG).NetNewsList$(APP_GROUP_SUFFIX)`, matched in both Mac Info.plists.
- **keep** `xcconfig/NetNewsWire_iOSTests_target.xcconfig` (11 lines) — iOS tests, already on `$(ORGANIZATION_IDENTIFIER)`.
- **keep** `xcconfig/NetNewsWire_project.xcconfig` (59 lines) — Project-wide compiler settings including `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` (:55), which every deletion PR has to respect.
- **keep** `xcconfig/NetNewsWire_project_release.xcconfig` (12 lines) — Release configuration with hardened runtime.
- **keep** `xcconfig/common/NetNewsWire_debug_identifiers.xcconfig` (5 lines) — `-DEBUG` bundle and group suffixes; kept so Debug and Release coexist (both App ID sets registered in the portal).
- **keep** `xcconfig/common/NetNewsWire_iOSextension_common.xcconfig` (9 lines) — Shared iOS extension settings.
- **keep** `xcconfig/common/NetNewsWire_macapp_target_common.xcconfig` (7 lines) — Mac Info.plist and bridging header paths.
- **keep** `xcconfig/common/NetNewsWire_macextension_common.xcconfig` (8 lines) — Common Mac extension settings.
- **keep** `xcconfig/common/NetNewsWire_release_identifiers.xcconfig` (4 lines) — Empty suffixes for Release.
- **keep** `xcconfig/common/NetNewsWire_version.xcconfig` (1 lines) — `CURRENT_PROJECT_VERSION`; reset at will.

## Totals

Recomputed from the 525 entries above by summing the line counts printed in each entry (entries without a count, such as nibs, plists and asset catalogs, add zero). Directory entries and the file entries inside them overlap (for example `Modules/Account/Sources/Account/CloudKit` and its files, `Shared/SmartFeeds` and its files, `Widget` and its files), some directory counts are Swift-only while others include nibs, and the plan-level numbers in `Plan.md` section 6 were measured differently, so these are approximate order-of-magnitude figures, not a diff prediction.

- **delete**: 132 entries, about 29,700 lines
- **adapt**: 165 entries, about 45,200 lines (the lines of files that are kept with edits, not the lines that change)
- **keep**: 226 entries, about 25,300 lines
- **decide**: 2 entries, 131 lines (`TodayFeedDelegate.swift`, `TodayWidget.swift`)

PR tags used: PR1 x16, PR2 x19, PR3 x24, PR4 x36, PR5 x42, PR6 x12, PR7 x13, PR8 x14, PR9 x30, PR10 x22, PR11 x1, PR12 x22; the remaining tagged-less entries are either deletions the plan does not schedule (dead code after a named PR, optional RSParser/RSWeb diet) or edits with no fixed PR.

## Not surveyed

The readers covered the paths above; the following exist in the repository and were not read file by file. Verdicts here are the plan's defaults, not survey results.

- `Resources/Themes` — a second copy of the eight theme bundles with the same file list as `Themes/`; the pbxproj references `Themes`, so confirm which copy is the source before editing a theme.
- `Modules/ActivityLog` and `Modules/ErrorLog` (sources, tests, `Package.swift`) — kept per the plan; `ActivityKind.fetchCloudKitStats` may stay as a harmless case.
- `Modules/RSCore/Sources/RSCore` beyond the ten files listed — ~76 generic AppKit/UIKit helpers, ObjC `NSMenuItem+RSCore` and `NSSharingService+Extension`, and `Modules/RSCore/Tests`; kept wholesale.
- `Modules/RSParser/Tests` (81 files) — feed parser tests and fixtures go with the optional Feeds diet; the OPML, XML, HTML and DateParser tests stay.
- `Modules/RSWeb/Tests` — `DictionaryTests`, `HTTPLinkPagingInfoTests` and the three `TestingURLProtocol*Tests` go with the RSWeb files marked delete; MacWebBrowser, SpecialCases, String and URL tests stay.
- Test targets and `Package.swift`/`README.md`/`.gitignore` files for Articles, RSCore, RSDatabase, RSTree, SyncDatabase, ActivityLog and ErrorLog — not read; keep (the Secrets, NewsBlur and FeedFinder equivalents go with their modules).
- Nibs and string catalogs beside surveyed controllers — `Mac/MainWindow/Base.lproj/MainWindow.xib`, `Sidebar/Base.lproj/SidebarView.xib`, `Timeline/Base.lproj/TimelineContainerView.xib`, `Timeline/TimelineTableView.xib`, `Mac/Preferences/Base.lproj/PreferencesWindow.xib`, `Mac/Preferences/General/Base.lproj/GeneralPreferencesView.xib` (refresh-interval popup PR5, JavaScript switch relabel PR7), the `Mac/{ActivityLog,CurrentActivity,ErrorLog}/Base.lproj` xibs, every `mul.lproj/*.xcstrings`, `iOS/Settings/SettingsTableViewCell.xib` and `SettingsComboTableViewCell.xib`; each follows its controller (delete a nib's `.xcstrings` with the nib, purge stale strings in PR12).
- Small Mac files not in the survey — `Mac/MainWindow/Timeline/{TimelineContainerView,TimelineLayout,TimelineTableRowView,TimelineTableView,TimelineWindowState}.swift`, `Mac/LogTextStyle.swift`, `Mac/NSOpenPanel+Extras.{h,m}`, `Mac/Preferences/Preferences{Controls,TableView}BackgroundView.swift`, `Mac/Resources/Credits.rtf`, `Mac/Resources/KeyboardShortcuts/KeyboardShortcuts.html`, `Mac/ShareExtension/icon.icns`; generic UI and resources, keep (credits and the shortcuts page get rebranded in PR12).
- Small Shared files not in the survey — `Shared/Extensions/{IconImageView,NSAttributedString+Extensions,Node+Extensions,RSImage+Extensions}.swift`, `Shared/ActivityLog/ActivityLogViewModel.swift`, `Shared/CurrentActivity/CurrentActivityViewModel.swift`; generic, keep (`NSAttributedString+Extensions` imports RSParser for entity decoding).
- `Shared/Resources/*KeyboardShortcuts.plist` — shortcut tables; the New Folder, Refresh, Go to Today, Hide Read Feeds, Get Info and Previous/Next Subscription entries go with their actions in PR9/PR10.
- `iOS/UIKit Extensions` other than `UIViewController+Extras.swift` — `SFSafariViewController+Extras`, `UIActivityViewController+Extras`, `Vibrant*`; generic, keep.
- `iOS/Resources/{About,Credits,Dedication,Thanks}.rtf` and `iOS/Resources/PrivacyInfo.xcprivacy` — About texts and the privacy manifest; rebrand in PR12 and check that no declared reason belongs to a removed feature.
- `Widget/Assets.xcassets` and `Widget/Resources/Localizable.xcstrings` — follow the widget.
- `buildscripts/clean_swift_whitespace.sh` and `clean_whitespace.rb` — formatting helpers; keep.
- Root files `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `LICENSE`, `CLAUDE.md`, `.editorconfig` — LICENSE stays (MIT attribution to upstream); CONTRIBUTING and CODE_OF_CONDUCT are upstream process documents to rewrite or drop with the README in PR12.
- Technotes not in the survey — `Accessibility.md`, `AvoidFeedParsing.markdown`, `CodingGuidelines.md`, `HiddenPrefs.md`, `HowToSupportNetNewsWire.markdown`, `ReleaseNotes-Mac.markdown`, `ReleaseNotes-iOS.markdown`, `Status.md`, `SwiftUI-UIKit-AppKit-Guidelines.markdown`, `Testing/StateRestoration.md`, `privacypolicy.markdown`, `Images/`; upstream documentation, and the plan adds only `Technotes/NetNewsList/ReadingList.md` (the folder exists and is empty).
- `NetNewsWire.xcodeproj/project.xcworkspace/contents.xcworkspacedata` and `xcshareddata/IDEWorkspaceChecks.plist` — Xcode metadata; keep.
