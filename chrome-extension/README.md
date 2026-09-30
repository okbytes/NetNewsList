# NetNewsList browser extension

A Manifest V3 extension for Chrome and other Chromium browsers (Helium, Arc, Brave) that saves pages to NetNewsList. Click the toolbar button (or press Control-Shift-S) to save the current page; right-click a link and choose **Save Link to NetNewsList** to save a link without opening it. Choose the mode in the extension’s options.

## Local mode: a Mac with the app

Saving opens `netnewslist://add?url=…&title=…`. The app saves the page, extracts it and syncs it through iCloud, then gives the focus back to the browser. The first save asks whether to open NetNewsList: tick **Always allow** once.

## Remote mode: a computer without the app

For a machine where the app can’t run and the Mac isn’t signed in to your Apple ID, such as a managed work computer. The extension writes the page straight into your iCloud through CloudKit Web Services, as a saved but not yet extracted article. Your Mac or iPhone downloads and extracts it the next time NetNewsList is open. Nothing but the sign-in token and a short queue of unsent pages is kept in the browser.

Setup:

1. In CloudKit Console, open the container’s **Tokens & Keys** and create an API token for the environment your apps use (Development for builds run from Xcode, Production for TestFlight or App Store builds). Set its sign-in callback to a URL redirect to any `https://` address you control; the page is never loaded.
2. Put the token in the extension, either in its options or, before loading the extension, in a `local-config.json` next to `manifest.json` (it’s ignored by git):
   ```json
   { "apiToken": "…", "callbackURL": "https://example.com", "environment": "development" }
   ```
3. In the options, choose **Straight to iCloud**, then **Sign In to iCloud**. Sign in with your Apple ID and tick **Keep me signed in** (about two weeks; otherwise 30 minutes).

When the sign-in expires, the toolbar badge shows **!** and pages wait in the queue (the badge shows how many) until you sign in again. Two limits: the NetNewsList app must have run once on some device so the iCloud zone exists, and Advanced Data Protection must stay off for the Apple ID, because iCloud gives no web sign-in to accounts that have it on.

## Install

1. Open `chrome://extensions` (or `helium://extensions`).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose this folder.
4. Pin the extension to the toolbar.

## Tests

`node --test chrome-extension/tests/*.test.mjs` checks the URL canonicalizer against the vectors the Swift tests use (`Modules/Account/Tests/AccountTests/Resources/url-canonicalization.json`), MD5, and the CloudKit calls against a fake server. A one-character difference in canonicalization would make the same page a second article, so change both implementations and the vectors together.
