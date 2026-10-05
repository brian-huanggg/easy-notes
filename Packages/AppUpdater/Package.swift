// swift-tools-version: 6.0
import PackageDescription

/// macOS 的自動更新（Sparkle）。不是外掛：App 負責組裝。
/// Sparkle 只有 macOS 版，用 target 的平台條件讓 iOS 建置不連結它（XcodeGen 的 package 依賴不能依平台過濾）。
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
