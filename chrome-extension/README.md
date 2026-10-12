# NetNewsList browser extension

A Manifest V3 extension for Chrome and other Chromium browsers (Helium, Arc, Brave) that saves pages to NetNewsList. Click the toolbar button (or press Control-Shift-S) to save the current page; right-click a link and choose **Save Link to NetNewsList** to save a link without opening it. Choose the mode in the extension’s options.

## Local mode: a Mac with the app

Saving opens a small window that hands the page to the app through `netnewslist://add?url=…&title=…` (an extension's toolbar popup can't open app links: it isn't a tab, so the browser drops them). The app saves the page, extracts it and syncs it through iCloud, then gives the focus back to the browser, and the window closes. The first save asks whether to open NetNewsList: tick **Always allow** and choose Open. macOS opens the NetNewsList copy registered for the link, which is the one Xcode builds; if another copy is running, a second one starts, so run the app from Xcode.

## Remote mode: a computer without the app

For a machine where the app can’t run and the Mac isn’t signed in to your Apple ID, such as a managed work computer. The extension writes the page straight into your iCloud through CloudKit Web Services, as a saved but not yet extracted article. Your Mac or iPhone downloads and extracts it the next time NetNewsList is open. Nothing but the sign-in token and a short queue of unsent pages is kept in the browser.

Setup:

1. In CloudKit Console, open the container’s **Tokens & Keys** and create an API token for the environment your apps use (Development for builds run from Xcode, Production for TestFlight or App Store builds). Set **Sign In Callback** to **URL Redirect** with an `https://` address you control, and **Allowed Origins** to **Any Domain** (the extension's requests come from a `chrome-extension://` origin, which differs on every machine). After you sign in, the browser does request that address, with the sign-in token in it, before the extension closes the tab; the extension spends the token at once (it checks the sign-in with iCloud), so a copy in that server's logs is useless. If iCloud refuses that check, the options page says so in red.
2. Put the token in the extension, either in its options or, before loading the extension, in a `local-config.json` next to `manifest.json` (it’s ignored by git):
   ```json
   { "apiToken": "…", "callbackURL": "https://example.com", "environment": "development" }
   ```
   If you enter them in the options instead, enter both the API token and the sign-in callback URL (the same address as in Console), then **Save Settings**.
3. In the options, choose **Straight to iCloud**, then **Sign In to iCloud**. Sign in with your Apple ID and tick **Keep me signed in** (about two weeks; otherwise 30 minutes).

When the sign-in expires, or a page can't be sent (offline, iCloud refused the request, out of space), the toolbar badge shows **!**, the tooltip and the options page say why, and the pages wait in the queue until you sign in again or press **Try Again Now**. A right-click save flashes **✓** when it's written. The only pages ever dropped are addresses that aren't web pages and pages whose own record iCloud rejects as invalid; they're listed under **Not saved** in the options page (with the reason) until you clear the list. Each saved page carries the time you saved it, so it sorts and shows the same "Date Saved" on every device. Two limits: the NetNewsList app must have run once on some device so the iCloud zone exists, and Advanced Data Protection must stay off for the Apple ID, because iCloud gives no web sign-in to accounts that have it on.

## Install

1. Open `chrome://extensions` (in Helium too).
2. Turn on **Developer mode**. On a managed computer, check `chrome://policy` first: if Developer mode is greyed out or unpacked extensions are blocked, the extension can't be installed there.
3. Click **Load unpacked** and choose this folder. Keep the folder where it is afterwards: an unpacked extension's identity (and with it the sign-in, queue and settings) comes from the folder's path.
4. Pin the extension to the toolbar.

## Tests

`node --test chrome-extension/tests/*.test.mjs` (or, without Node, `bun test ./chrome-extension/tests/*.test.mjs`) checks the URL canonicalizer against the vectors the Swift tests use (`Modules/Account/Tests/AccountTests/Resources/url-canonicalization.json`), MD5, and the CloudKit calls against a fake server (the record format, the queue, sign-in and error handling). It has never been run against real iCloud: the first sign-in and save are the real test. A one-character difference in canonicalization would make the same page a second article, so change both implementations and the vectors together.
