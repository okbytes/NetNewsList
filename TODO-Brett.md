# TODO for Brett

Things only you can do. Everything else is tracked in `Technotes/NetNewsList/Plan.md`; how the app works is in `Technotes/NetNewsList/ReadingList.md`.

## Updating the work Mac

On this Mac, with everything committed: `scripts/release-work-mac.sh` builds, notarizes and publishes the next version (pass a number, like `scripts/release-work-mac.sh 2.0`, to choose it). Then on the work Mac: `gh api repos/okbytes/NetNewsList/contents/scripts/install-work-mac.sh -H "Accept: application/vnd.github.raw" | bash`. A fresh install asks once for the API token: the `apiToken` in `local-config.json` in the repo folder on this Mac.

## 1. Before a TestFlight or App Store build

Only if you ever ship a TestFlight or App Store build (Plan.md, 2026-10-09: the apps stay on Development). Xcode builds use CloudKit's Development environment, and that is where your data lives. Never click "Reset Development Environment" in CloudKit Console; it deletes everything saved.

- [ ] CloudKit Console: deploy the Development schema to Production (it includes `Article.datePublished` as a timestamp, which the apps and the Matter import write).
- [ ] CloudKit Console → the container → Tokens & Keys: create a **Production** API token (the current one only works for Development), put it in `local-config.json` with `"environment": "production"`, and rebuild the work copy.
- [ ] Try the TestFlight build on the iPhone, the Mac and the work Mac before relying on it.

## 2. When you get to it

- [ ] Install the 2026-10-24 stability pass: `scripts/install-mac.sh`, `scripts/mine.sh`, and the next work-Mac release (above). Then:
  - Save a page on the Mac and it shows up on the iPhone; archive it on the iPhone and it leaves the Mac's Queue (the 2026-10-22 cleanups stopped using the `Account` zone).
  - iPhone, app closed: share a link from an app other than Safari, leave the phone a few hours, then open the app. The page saves rather than showing "Couldn't save the page".
  - iPhone: save a page in Airplane Mode, open the app a few times over 15 minutes, then turn Airplane Mode off and open it again. The page saves.
  - Mac: select two lines of links in Notes and choose Save to NetNewsList from the Services menu. Both are saved.
  - Work Mac: quit while it syncs on a slow or missing network. It quits within about 12 seconds, and the next launch is still signed in (or signs in again by itself).
  - Tell Claude if anything stalls or the Error Log shows an iCloud error.
- [ ] After the next `scripts/install-mac.sh` and `scripts/mine.sh`, look at the smaller count chip on both (centered on the title's lowercase letters, like your mockup, and now the title's color), on the Mac the bold title, the chip in an inactive window, and the compact toolbar buttons.
- [ ] Once the work Mac runs the next release (1.4 or later), delete the old `Account` zone: in CloudKit Console, open `iCloud.eitherslice.NetNewsList` (Development), act as your iCloud account, find the zones of the private database and delete `Account`. Since 2026-10-22 the apps neither read nor write it (it holds one feed record and one account record); an older build still running somewhere would just create it again, empty. Don't touch the `Articles` zone: that's your reading list.
