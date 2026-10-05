// swift-tools-version: 6.0
import PackageDescription

/// macOS auto-update (Sparkle). Not a plugin: the App assembles it.
/// Sparkle exists only on macOS; a platform condition on the target keeps iOS builds from linking it (XcodeGen package dependencies cannot filter by platform).
let package = Package(
    name: "AppUpdater",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AppUpdater", targets: ["AppUpdater"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "AppUpdater", dependencies: [
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
        ]),
    ]
)
