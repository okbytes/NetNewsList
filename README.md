<img src=Technotes/Images/icon_1024.png height=128 width=128 style="display: block; margin: auto;">

# NetNewsList

NetNewsList is a personal reading list for the Mac and iPhone: save a web page from anywhere, read it later, offline, in a clean three-pane reader. It is a fork of [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire), keeping its reading experience (timeline, article view, themes, keyboard navigation, search) and replacing feeds with saved pages.

- **Saving.** Add Article (⌘N, with the clipboard’s URL filled in), the share sheet on both platforms, a “Save to NetNewsList” action in Shortcuts and Siri, `netnewslist://add?url=…&title=…`, dragging a link onto the Mac window, and a browser extension for Chrome and other Chromium browsers (`chrome-extension/`). The extension also works on a computer without the app, writing straight to your iCloud.
- **Reading offline.** When a page is saved, the app downloads it once, extracts the article with Readability.js in a hidden web view (the page’s own scripts never run), sanitizes it with DOMPurify, and keeps the text and images. Saved pages stay readable after the original disappears.
- **Lists.** Inbox (unread), Starred, Archive (read) and All. Archiving is marking as read; deleting removes a page everywhere.
- **Sync.** Only through your private iCloud database (CloudKit). There are no servers and no accounts other than iCloud.

## Building

You need Xcode and, to run on devices with iCloud, a paid Apple developer account. Set your team in `xcconfig/common/NetNewsWire_codesigning_common.xcconfig` (`DEVELOPMENT_TEAM`, `ORGANIZATION_IDENTIFIER`) or in `../SharedXcodeSettings/DeveloperSettings.xcconfig`, then build the `NetNewsWire` (Mac) or `NetNewsWire-iOS` scheme. The app’s iCloud container is `iCloud.$(ORGANIZATION_IDENTIFIER).NetNewsList`.

Tests (no signing needed):

```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -testPlan NetNewsWire-CI \
  -xcconfig .github/macos-ci-no-signing.xcconfig -destination "platform=macOS,arch=arm64"
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS -testPlan NetNewsWire-iOS \
  -xcconfig .github/ios-ci-no-signing.xcconfig -destination "platform=iOS Simulator,name=iPhone Air"
node --test chrome-extension/tests/*.test.mjs
```

## Documentation

- [Technotes/NetNewsList/ReadingList.md](Technotes/NetNewsList/ReadingList.md): how saving, extraction, sync and offline images work, and the traps to avoid.
- [Technotes/NetNewsList/Plan.md](Technotes/NetNewsList/Plan.md): the conversion plan and what each step changed.
- [chrome-extension/README.md](chrome-extension/README.md): installing and setting up the browser extension.
- [Technotes/NetNewsList/Privacy.md](Technotes/NetNewsList/Privacy.md): what is stored where.

## License

MIT, like NetNewsWire. NetNewsWire is © Brent Simmons and contributors; see [LICENSE](LICENSE).
