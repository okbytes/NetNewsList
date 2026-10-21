<img src=Technotes/Images/icon_1024.png height=128 width=128 style="display: block; margin: auto;">

# NetNewsList

NetNewsList is a personal reading list for the Mac and iPhone: save a web page from anywhere, read it later, offline, in a quiet reader: the list beside the article on the Mac and iPad, one after the other on the iPhone. It is a fork of [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire), keeping its list, article view and keyboard navigation and replacing feeds with saved pages.

- **Saving.** Add Article (⌘N, with the clipboard’s URL filled in), the share sheet on both platforms, a “Save to NetNewsList” action in Shortcuts and Siri, `netnewslist://add?url=…&title=…`, dragging a link onto the Mac window, and Save to NetNewsList in the Mac’s Services menu for a web address selected in any app. On a Mac whose macOS isn’t signed in to your iCloud (a work computer), the Mac app signs in to iCloud by itself (`scripts/build-work-mac.sh`).
- **Reading offline.** When a page is saved, the app downloads it once, extracts the article with Readability.js in a hidden web view (the page’s own scripts never run), sanitizes it with DOMPurify, and keeps the text and images. Saved pages stay readable after the original disappears.
- **Queue and Archive.** Saved pages wait in the Queue, oldest first. Archiving moves a page to the Archive and Move to Queue brings it back; deleting removes it everywhere.
- **Sync.** Only through your private iCloud database (CloudKit). There are no servers and no accounts other than iCloud.

## Building

You need Xcode and, to run on devices with iCloud, a paid Apple developer account. Set your team in `xcconfig/common/NetNewsWire_codesigning_common.xcconfig` (`DEVELOPMENT_TEAM`, `ORGANIZATION_IDENTIFIER`) or in `../SharedXcodeSettings/DeveloperSettings.xcconfig`, then build the `NetNewsWire` (Mac) or `NetNewsWire-iOS` scheme. The app’s iCloud container is `iCloud.$(ORGANIZATION_IDENTIFIER).NetNewsList`.

Tests (no signing needed):

```bash
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire -testPlan NetNewsWire-CI \
  -xcconfig .github/macos-ci-no-signing.xcconfig -destination "platform=macOS,arch=arm64"
xcodebuild test -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS -testPlan NetNewsWire-iOS \
  -xcconfig .github/ios-ci-no-signing.xcconfig -destination "platform=iOS Simulator,name=iPhone Air"
```

## Documentation

- [Technotes/NetNewsList/ReadingList.md](Technotes/NetNewsList/ReadingList.md): how saving, extraction, sync and offline images work, and the traps to avoid.
- [Technotes/NetNewsList/Plan.md](Technotes/NetNewsList/Plan.md): the conversion plan and what each step changed.
- [Technotes/NetNewsList/Privacy.md](Technotes/NetNewsList/Privacy.md): what is stored where.

## License

MIT, like NetNewsWire. NetNewsWire is © Brent Simmons and contributors; see [LICENSE](LICENSE).
