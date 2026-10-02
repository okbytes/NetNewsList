// swift-tools-version:6.2
import PackageDescription

// Fetches and extracts real web pages with the app's Extraction module, to check
// extraction quality without running the app. See README.md.
let package = Package(
	name: "extract-page",
	platforms: [.macOS(.v15)],
	dependencies: [.package(path: "../../Modules/Extraction")],
	targets: [
		.executableTarget(
			name: "extract-page",
			dependencies: [.product(name: "Extraction", package: "Extraction")],
			swiftSettings: [.swiftLanguageMode(.v5)]
		)
	]
)
