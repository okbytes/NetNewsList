# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NetNewsList: a personal, iCloud-only reading list for Mac and iPhone, forked from NetNewsWire. Pages are saved by URL, extracted with Readability.js at save time, synced through the user's private CloudKit database, and read offline in NetNewsWire's three-pane UI. There are no feeds, no other accounts and no servers.

**Start here when picking the work up:**
1. `Technotes/NetNewsList/ReadingList.md`: how saving, extraction, sync and offline images work, and the traps. Read it before changing sync, retention, account, extraction or ingress code.
2. `Technotes/NetNewsList/Plan.md`: the decisions (D1–D7), the data-loss traps (section 4) and a **Progress** note per PR at the end of section 5. The last note ("merge and wrap-up") lists what is still open.
3. `TODO-Brett.md`: what only the user can do (device testing, CloudKit Console, the work-computer extension setup).

**Branch:** NetNewsList work lands on `main` (pushed to `origin`, github.com/okbytes/NetNewsList, which is public). Upstream NetNewsWire is the `upstream` remote; to sync, merge `upstream/main` into `main` (the 2026-10-07 sync's Progress note in `Plan.md` says how its conflicts were resolved). GitHub lists the repository as a fork of Ranchero-Software/NetNewsWire, so pass `--repo okbytes/NetNewsList` to `gh pr create` or the PR goes upstream.

## Build and test

Unsigned builds and tests use the CI xcconfigs. Every build is warnings-as-errors, so a clean build means zero warnings.

```bash
# Mac app and Mac test plan (includes module tests: Account, ArticlesDatabase, Extraction, …)
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination "platform=macOS,arch=arm64" \
  -xcconfig .github/macos-ci-no-signing.xcconfig build
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -testPlan NetNewsWire-CI \
  -destination "platform=macOS,arch=arm64" -xcconfig .github/macos-ci-no-signing.xcconfig

# iOS app and iOS test plan (use a simulator that isn't the user's booted one; the "NetNewsList" simulator, an iPhone Air on iOS 27, is this project's)
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS -destination "platform=iOS Simulator,name=NetNewsList" \
  -xcconfig .github/ios-ci-no-signing.xcconfig build
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS -testPlan NetNewsWire-iOS \
  -destination "platform=iOS Simulator,name=NetNewsList" -xcconfig .github/ios-ci-no-signing.xcconfig

# Extraction module alone (fast), browser extension, lint
(cd Modules/Extraction && xcodebuild test -scheme Extraction -destination "platform=macOS,arch=arm64")
node --test chrome-extension/tests/*.test.mjs
swiftlint lint --strict
```

- Pass `-derivedDataPath <somewhere in the scratchpad>` to keep builds out of the user's Xcode DerivedData, and use a separate path for any parallel agent.
- Don't run module tests with `swift test`: `AppConfig` force-unwraps `CFBundleExecutable` and crashes outside an app bundle. Use the test plans.
- An unsigned process traps when it creates a `CKContainer`; CloudKit is never touched under unit tests (`Platform.isRunningUnitTests`). Don't launch the unsigned app expecting iCloud to work, and don't run the signed app without asking: it writes to the user's real iCloud data.
- `scripts/mine.sh` builds the signed Debug iOS app into Xcode's default DerivedData, installs it on the paired iPhone in place and launches it (`--help` for options); rerunning it after a new signing certificate keeps the app launching. Don't run it without asking: it replaces the build on the user's phone, which syncs with their real iCloud data.
- Real-page extraction can be checked without the app: `Tools/extract-page` (see its README).
- `./buildscripts/make_safari_ext_js.sh` regenerates `Shared/ShareExtension/SafariExt.js` from the vendored Readability.js and DOMPurify; rerun it after updating them.

## Project structure

- `Modules/`: local Swift packages (RSCore, RSParser, RSWeb, RSDatabase, RSTree, Articles, ArticlesDatabase, SyncDatabase, Account, CloudKitSync, Images, HTMLMetadata, ActivityLog, ErrorLog, **Extraction**). Apps reference package products by name; new packages need `XCSwiftPackageProductDependency` and build-file entries in `project.pbxproj` (copy the `HTMLMetadata` or `Extraction` entries).
- `Shared/`: code for both apps, including `Extraction/` (`ExtractionCoordinator`, `ExtractedContentFormatter`, `SavedArticleRequestProcessor`), `ArticleAssets/` (offline images), `AddArticle/`, `AppIntents/`, `ShareExtension/` (the files the share extensions compile), `SmartFeeds/` (Inbox, Starred, Archive, All).
- `Mac/`, `iOS/`: platform UI. `chrome-extension/`: the Chromium extension (local and remote mode). `Technotes/NetNewsList/`: this project's docs.
- The Xcode project uses **file-system-synchronized groups**: new files under `Mac/`, `iOS/`, `Shared/` join the app targets automatically; extension targets compile only the files listed in their `PBXFileSystemSynchronizedBuildFileExceptionSet`. Build settings live in `xcconfig/` only; a build phase fails the Mac build if `project.pbxproj` gains `buildSettings`. Xcode sometimes rewrites the project file while the user has it open; build on top of its version.
- Identity: team `P4RDBS9676`, organization identifier `eitherslice`, bundle IDs `eitherslice.NetNewsList` and `eitherslice.NetNewsList.iOS` (`-DEBUG` suffix in Debug), container `iCloud.eitherslice.NetNewsList`, URL scheme `netnewslist://`. `PRODUCT_MODULE_NAME` is still `NetNewsWire` (tests use `@testable import NetNewsWire`).
- The browser extension's CloudKit API token (Development) is in the git-ignored `chrome-extension/local-config.json`. Never commit it; the repository is public.

## Working conventions

- Commit messages are one plain sentence; no `Co-Authored-By` or other agent attribution lines in commits or PR descriptions.
- After each piece of work, add or update a **Progress** note in `Plan.md` (what changed, deviations from the plan, what's left) so the next session can pick up from the files alone.

## Code formatting

Prefer idiomatic modern Swift.

Prefer `if let x` and `guard let x` over `if let x = x` and `guard let x = x`.

Don’t use `...` or `…` in Logger messages.

Guard statements should always put the return in a separate line.

Don’t do force unwrapping of optionals.

## Things to Know

Just because unit tests pass doesn’t mean a given bug is fixed. It may not have a test. It may not even be testable — it may require manual testing. Nothing in NetNewsList's UI has been run on a device by an agent; the user's checklist in `TODO-Brett.md` is the record of what has been verified by hand.
