# NetNewsList browser extension

A Manifest V3 extension for Chrome and other Chromium browsers (Helium, Arc, Brave) that saves pages to NetNewsList.

## Local mode (this version)

For a Mac that has the NetNewsList app. Clicking the toolbar button (or pressing Control-Shift-S) opens `netnewslist://add?url=…&title=…`, and the app saves the page, extracts it and syncs it through iCloud. The app doesn’t come forward: focus returns to the browser. Right-click a link and choose **Save Link to NetNewsList** to save a link without opening it.

The first save asks whether to open NetNewsList. Tick **Always allow** once; later saves are silent.

## Install

1. Open `chrome://extensions` (or `helium://extensions`).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose this `chrome-extension` folder.
4. Pin the extension to the toolbar.

## Remote mode (planned, PR8b)

For a machine without the app, such as a managed work computer: the extension writes the page straight into your iCloud through CloudKit Web Services, and your Mac or iPhone extracts it. See `Technotes/NetNewsList/Plan.md`, section 3.4.
