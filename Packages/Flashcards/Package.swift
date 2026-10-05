// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flashcards",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Flashcards", targets: ["Flashcards"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
        // FSRS-6 只在 main（最後一個 release v5.0.0 是 FSRS-5），固定 commit；升級時重跑 scripts/fsrs-vectors.py 的回歸測試
        .package(url: "https://github.com/open-spaced-repetition/swift-fsrs.git",
                 revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9"),
        // 卡片中的 LaTeX 公式以原生方式排版（複習畫面不開 WebView）
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
    ],
    targets: [
        // 卡片解析、FSRS 排程、複習介面；不是檔案類型（卡片寫在 .md 裡）
        .target(
            name: "Flashcards",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
                .product(name: "FSRS", package: "swift-fsrs"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(name: "FlashcardsTests", dependencies: [
            "Flashcards", .product(name: "EasyNotesCore", package: "EasyNotesCore"),
        ], resources: [.copy("Fixtures")]),
    ]
)
