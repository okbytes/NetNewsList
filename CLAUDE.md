# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NetNewsList: a personal, iCloud-only reading list for Mac and iPhone, forked from NetNewsWire. Pages are saved by URL, extracted with Readability.js at save time, synced through the user's private CloudKit database, and read offline in NetNewsWire's three-pane UI. There are no feeds, no other accounts and no servers.

**Start here when picking the work up:**
1. `Technotes/NetNewsList/ReadingList.md`: how saving, extraction, sync and offline images work, and the traps. Read it before changing sync, retention, account, extraction or ingress code.
2. `Technotes/NetNewsList/Plan.md`: the decisions (D1–D7), the data-loss traps (section 4) and a **Progress** note per PR at the end of section 5. The last note ("merge and wrap-up") lists what is still open.
3. `TODO-Brett.md`: what only the user can do (updating the work Mac, CloudKit Console, open decisions).

**Branch:** NetNewsList work lands on `main` (pushed to `origin`, github.com/okbytes/NetNewsList, which is public). Upstream NetNewsWire is the `upstream` remote; to sync, merge `upstream/main` into `main` (the 2026-10-07 sync's Progress note in `Plan.md` says how its conflicts were resolved). GitHub lists the repository as a fork of Ranchero-Software/NetNewsWire, so pass `--repo okbytes/NetNewsList` to `gh pr create` or the PR goes upstream.

## Build and test

Unsigned builds and tests use the no-signing xcconfigs in `.github/`. Every build is warnings-as-errors, so a clean build means zero warnings. There is no CI: the GitHub Actions workflow was removed on 2026-10-11 to save compute, so build, test and lint locally before pushing. Merging upstream NetNewsWire brings `.github/workflows/` back; delete it again.

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

# Extraction module alone (fast), lint
(cd Modules/Extraction && xcodebuild test -scheme Extraction -destination "platform=macOS,arch=arm64")
swiftlint lint --strict
```

- Pass `-derivedDataPath <somewhere in the scratchpad>` to keep builds out of the user's Xcode DerivedData, and use a separate path for any parallel agent.
- xcodebuild registers every Mac app it builds with LaunchServices and never unregisters it, so each scratchpad build adds its own Save to NetNewsList (Dev) to the user's Services menu and can answer the app's links. Run `scripts/unregister-stale-builds.sh` when you're done with Mac builds; it leaves the installed app and Xcode's own DerivedData alone.
- Don't run module tests with `swift test`: `AppConfig` force-unwraps `CFBundleExecutable` and crashes outside an app bundle. Use the test plans.
- An unsigned process traps when it creates a `CKContainer`; CloudKit is never touched under unit tests (`Platform.isRunningUnitTests`). Don't launch the unsigned app expecting iCloud to work, and don't run the signed app without asking: it writes to the user's real iCloud data.
- `scripts/mine.sh` builds the signed Debug iOS app into Xcode's default DerivedData, installs it on the paired iPhone in place and launches it (`--help` for options); rerunning it after a new signing certificate keeps the app launching. Don't run it without asking: it replaces the build on the user's phone, which syncs with their real iCloud data.
- `scripts/install-mac.sh` builds the Mac app in Release (development-signed, so still the CloudKit Development environment) and installs it as `~/Applications/NetNewsList.app`, the user's everyday copy; its first install copied NetNewsList Dev's local data into it. Don't run it without asking: it quits and replaces that app. The Mac Debug build is **NetNewsList Dev** (`NetNewsList Dev.app`, link scheme `netnewslist-dev://`), so only the installed app answers `netnewslist://` links; both see the same iCloud data.
- `scripts/build-work-mac.sh` builds the work-computer copy: Developer ID-signed, notarized when the `netnewslist-notary` notarytool profile exists, no iCloud entitlement (`xcconfig/NetNewsList_work.xcconfig`, bundle ID `eitherslice.NetNewsList.Web`), syncing over CloudKit Web Services with its own sign-in (ReadingList.md, "iCloud on the web"). It builds in the API token from the git-ignored `local-config.json` at the repository's root. Never open the app it builds on this Mac: it claims `netnewslist://` from the everyday copy. `scripts/release-work-mac.sh [version]` publishes it as a GitHub release tagged `v<version>` (the version given, or the last release's with its last number raised by one; it commits the version to `xcconfig/common/NetNewsWire_version.xcconfig` first, the one place every target's version is set), built with `--no-token` (the repository is public; the app asks for the token once), and `scripts/install-work-mac.sh` installs the latest release on the work Mac with only `gh` (it's meant to be piped from `gh api …/contents/scripts/install-work-mac.sh`, like Tinycast's installer). Publishing a release is public: ask first. Any build can try the web path with the launch argument `-NetNewsListICloudTransport web` (it then asks for the API token at sign-in, and it writes to the user's real iCloud data, so ask first).
- Real-page extraction can be checked without the app: `Tools/extract-page` (see its README).
- `./buildscripts/make_safari_ext_js.sh` regenerates `Shared/ShareExtension/SafariExt.js` from the vendored Readability.js and DOMPurify; rerun it after updating them.

## Project structure

- `Modules/`: local Swift packages (RSCore, RSParser, RSWeb, RSDatabase, Articles, ArticlesDatabase, SyncDatabase, Account, CloudKitSync, Images, HTMLMetadata, ActivityLog, ErrorLog, **Extraction**). Apps reference package products by name; new packages need `XCSwiftPackageProductDependency` and build-file entries in `project.pbxproj` (copy the `HTMLMetadata` or `Extraction` entries).
- `Shared/`: code for both apps, including `Extraction/` (`ExtractionCoordinator`, `ExtractedContentFormatter`, `SavedArticleRequestProcessor`), `ArticleAssets/` (offline images), `AddArticle/`, `AppIntents/`, `ShareExtension/` (the files the share extensions compile), `SmartFeeds/` (Queue and Archive).
- `Mac/`, `iOS/`: platform UI. `Technotes/NetNewsList/`: this project's docs. The Chromium extension was removed on 2026-10-14 (`git log --diff-filter=D -- chrome-extension` finds the commit).
- The Xcode project uses **file-system-synchronized groups**: new files under `Mac/`, `iOS/`, `Shared/` join the app targets automatically; extension targets compile only the files listed in their `PBXFileSystemSynchronizedBuildFileExceptionSet`. Build settings live in `xcconfig/` only; a build phase fails the Mac build if `project.pbxproj` gains `buildSettings`. Xcode sometimes rewrites the project file while the user has it open; build on top of its version.
- Identity: team `P4RDBS9676`, organization identifier `eitherslice`, bundle IDs `eitherslice.NetNewsList` and `eitherslice.NetNewsList.iOS` (`-DEBUG` suffix in Debug), container `iCloud.eitherslice.NetNewsList`, URL scheme `netnewslist://` (`netnewslist-dev://` for the Mac Debug build, NetNewsList Dev). `PRODUCT_MODULE_NAME` is still `NetNewsWire` (tests use `@testable import NetNewsWire`).
- The CloudKit Web Services API token (Development) is in the git-ignored `local-config.json` at the repository's root. Never commit it; the repository is public.

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

Just because unit tests pass doesn’t mean a given bug is fixed. It may not have a test. It may not even be testable — it may require manual testing. Nothing in NetNewsList's UI has been run on a device by an agent; what the user still has to check by hand goes in `TODO-Brett.md`.
