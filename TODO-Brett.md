# TODO for Brett

Things only you can do. Everything else is tracked in `Technotes/NetNewsList/Plan.md`; how the app works is in `Technotes/NetNewsList/ReadingList.md`.

## Updating the work Mac

On this Mac, with everything committed: `scripts/release-work-mac.sh` builds, notarizes and publishes the next version (pass a number, like `scripts/release-work-mac.sh 2.0`, to choose it). Then on the work Mac: `gh api repos/okbytes/NetNewsList/contents/scripts/install-work-mac.sh -H "Accept: application/vnd.github.raw" | bash`. A fresh install asks once for the API token: the `apiToken` in `local-config.json` in the repo folder on this Mac.

## 1. Before a TestFlight or App Store build

Only if you ever ship a TestFlight or App Store build (Plan.md, 2026-10-09: the apps stay on Development). Xcode builds use CloudKit's Development environment, and that is where your data lives. Never click "Reset Development Environment" in CloudKit Console; it deletes everything saved.

- [ ] CloudKit Console: deploy the Development schema to Production (it includes `Article.datePublished` as a timestamp, which the apps and the Matter import write).
- [ ] CloudKit Console → the container → Tokens & Keys: create a **Production** API token (the current one only works for Development), put it in `local-config.json` with `"environment": "production"`, and rebuild the work copy.
- [ ] Try the TestFlight build on the iPhone, the Mac and the work Mac before relying on it.

## 2. Decisions (no rush)

- [ ] Backups (File > Show Backups in Finder) stay on this Mac, which has no Time Machine. Copy the folder somewhere else now and then, or ask Claude to have the app write them to a folder you choose (iCloud Drive, Google Drive). Keep `~/Downloads/matter_data_brett_1791749808` too: it's the original text of the 93 Matter pages.
- [ ] Both apps ask for notification permission at launch, only to badge the app icon with the Queue count. Keep the badge, or drop it and the prompt?
- [ ] The `mine.sh` scripts in verbatim, scanner-ios and browser-ios can't install on a phone that isn't registered with your team yet (they lack `-allowProvisioningDeviceRegistration`, which workout-ios and this repo pass). Want Claude to add it there?
- [ ] Should pages that come back nearly empty (JavaScript-built sites) automatically retry with the live page? Today it's manual (Retry with Live Page) because the live page runs the site's own scripts.
- [ ] Optional cleanups Claude left alone: removing the leftover feed-notifications setting, purging stale strings (best done from Xcode), deleting the unused RSS/Atom parsers (needs an audit), and removing the Account zone from iCloud (only after sync has been stable for a while).
