# TODO for Brett

Things only you can do. Everything else is tracked in `Technotes/NetNewsList/Plan.md`; how the app works is in `Technotes/NetNewsList/ReadingList.md`.

## 1. Try it on your devices

Your iPhone has the current build (installed 2026-10-10 with `scripts/mine.sh`; rerun it after pulling changes). On the Mac, run the NetNewsWire scheme from Xcode (clean build, ⇧⌘K, once: the share extensions changed). Claude checked iCloud sync between the Mac app and the simulator on 2026-10-10 (Plan.md, "first two-device run"); nothing else below has been tried on a device.

- [ ] **iCloud sync (PR5–6).** On the real iPhone: the whole item, especially delete and the two relaunches, which Claude didn't run. Also note how long a page saved on the Mac takes to appear while the iPhone app stays open (the simulator never got iCloud pushes). Save a page on the Mac (⌘N). It appears on the iPhone within about a minute while the app is open. Archive it on the iPhone and the Mac's Inbox count drops; star it on the Mac and it shows in Starred on the iPhone. Save the same URL again with `/` or `?utm_source=x` added: still one row. Quit and relaunch both apps twice: nothing disappears. In CloudKit Console (Development), the Articles zone has `s|…` and `a|…` records and the Account zone has one Reading List feed record.
- [ ] **Extraction (PR7).** Save 6–8 varied pages (news, blog, docs, a very long page, a JavaScript-heavy site). Each goes from "Saving the page…" to full text. On the one that fails, right-click → Retry with Live Page. Show Original (⌘⇧R, globe button) works on the Mac and opens the in-app browser on the iPhone. The very long page's `Article` record in CloudKit Console has `contentHTMLAsset`.
- [ ] **Saving from elsewhere (PR8).** Share → NetNewsList from Safari on both platforms. Share from iPhone Safari with the app force-quit, then open the app: it's saved and reaches the Mac. Shortcuts has "Save to NetNewsList" on both platforms; a Shortcut passing "Get Article using Safari Reader" as Body arrives already filled in. The same URL saved twice never makes a second row.
- [ ] **Safari capture.** Share a page you're signed in to (a paywalled article you subscribe to) from Safari: the saved copy has the full text.
- [ ] **Browser extension, this Mac (PR8).** Load `chrome-extension/` unpacked in Chrome or Helium, click the toolbar button, tick "Always allow" once, then save a few more pages: no more prompts. (If Chrome asks again on each new site, tell Claude.)
- [ ] **Mac interface (PR9).** Sidebar shows Inbox, Starred, Archive, All (⌘1–⌘4). Archive and Archive All move articles to Archive on both devices. Delete Article… asks, then the article is gone here and, after Sync Now, on the iPhone. Dragging a link from the browser onto the sidebar or timeline saves it. Favicons show next to articles and in the article header. Relaunch returns to the last list. If the toolbar lacks Add Article or the globe, right-click it → Customize Toolbar.
- [ ] **iPhone interface (PR10).** iPhone and iPad layouts. Sidebar shows only the four lists; long-press a list for Archive All; + opens Add Article. Timeline: Delete in the context menu and on a full swipe (asks first; a full swipe used to star). Search, swipes, state restoration. Next Unread now continues in the Inbox instead of walking the sidebar.
- [ ] **Offline images (PR11).** Save an image-heavy article on the Mac, open the iPhone app once online, then turn on Airplane Mode: text and images both show. A page with hundreds of images still saves (40 images are kept per article; the rest load when online). Deleting an article removes its images.

## 2. Confirm the browser extension's iCloud field types

The extension's remote mode writes iCloud records itself, and Claude couldn't verify the field types against the app's code (its permission check blocked reading `Modules/Account/Sources/Account/CloudKit`). Claude could read that folder on 2026-10-10, so the next session can do this; or check them yourself.

- [ ] In CloudKit Console → Development → Schema → Record Types:
  - `ArticleStatus`: `read`, `starred`, `webFeedExternalID` are **String**.
  - `Article`: `webFeedURL`, `uniqueID`, `url`, `externalURL`, `title` are **String**; `articleStatus` is a **Reference**.
- [ ] Or tell Claude it may read `Modules/Account/Sources/Account/CloudKit`; it will check the types and add the missing test (an `Article` record with no body becomes an article waiting to be saved).

## 3. Set up the browser extension on the work computer (PR8b)

- [ ] Copy the `chrome-extension` folder **including `local-config.json`** (it holds the CloudKit API token and isn't in git) to the work computer. Or copy it without that file and paste the token into the extension's options.
- [ ] `helium://extensions` → Developer mode → Load unpacked → the folder. Pin it.
- [ ] Options → "Straight to iCloud" → Sign In to iCloud. Tick **Keep me signed in** (about two weeks; otherwise 30 minutes).
- [ ] Save three pages. Within a minute they show on the Mac or iPhone and fill in with the text while an app is open. Saving the same pages from the Mac makes no duplicates.
- [ ] Options → Sign Out, then save a page: the badge shows **!** and the page waits instead of being lost.
- [ ] Keep Advanced Data Protection **off** for your Apple ID, or web sign-in stops working.

## 4. Before a TestFlight or App Store build

Not needed while the apps are installed from Xcode: those builds use CloudKit's Development environment, and that is where your data lives. Never click "Reset Development Environment" in CloudKit Console; it deletes everything saved.

- [ ] CloudKit Console: deploy the Development schema to Production.
- [ ] CloudKit Console → the container → Tokens & Keys: create a **Production** API token (the current one only works for Development), and switch the extension's options to Production with it.
- [ ] Repeat sections 1 and 3 on the TestFlight build.

## 5. Decisions (no rush)

- [ ] Opening an article archives it (selecting marks it read, and read is Archive). Keep that, or archive only when you say so?
- [ ] Both apps ask for notification permission at launch, only to badge the app icon with the Inbox count. Keep the badge, or drop it and the prompt?
- [ ] The `mine.sh` scripts in verbatim, scanner-ios and browser-ios can't install on a phone that isn't registered with your team yet (they lack `-allowProvisioningDeviceRegistration`, which workout-ios and this repo pass). Want Claude to add it there?
- [ ] Should pages that come back nearly empty (JavaScript-built sites) automatically retry with the live page? Today it's manual (Retry with Live Page) because the live page runs the site's own scripts.
- [ ] Optional cleanups Claude left alone: removing the leftover feed-notifications setting, purging stale strings (best done from Xcode), deleting the unused RSS/Atom parsers (needs an audit), and removing the Account zone from iCloud (only after sync has been stable for a while).
