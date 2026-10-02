# extract-page

Runs the app's extraction (`Modules/Extraction`: `PageFetcher` and `ReadabilityWebExtractor`) on real pages from the command line, without the app or iCloud.

```bash
cd Tools/extract-page
swift build
.build/debug/extract-page https://paulgraham.com/greatwork.html https://example.com/
.build/debug/extract-page --live https://developer.apple.com/documentation/webkit/wkwebview
.build/debug/extract-page --html https://example.com/ > page.html
```

Each URL prints `OK` (readable), `THIN` (under 100 characters of article text, which the app treats as a failure) or `FAIL` with the error, plus timing, title, byline, site name and publication date. `--live` loads the page with its JavaScript on first, like the app's Retry with Live Page.
