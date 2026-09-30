// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "Extraction",
	platforms: [.macOS(.v15), .iOS(.v17)],
	products: [
		.library(
			name: "Extraction",
			type: .dynamic,
			targets: ["Extraction"])
	],
	dependencies: [
		.package(path: "../RSCore")
	],
	targets: [
		.target(
			name: "Extraction",
			dependencies: [
				"RSCore"
			],
			resources: [
				.copy("JavaScript")
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances"),
				.unsafeFlags(["-warnings-as-errors"])
			]
		),
		.testTarget(
			name: "ExtractionTests",
			dependencies: ["Extraction"],
			resources: [
				.copy("Fixtures")
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances")
			]
		)
	]
)
