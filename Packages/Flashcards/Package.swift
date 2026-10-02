// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flashcards",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Flashcards", targets: ["Flashcards"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
    ],
    targets: [
        // 卡片解析、FSRS 排程、複習介面；不是檔案類型（卡片寫在 .md 裡）
        .target(
            name: "Flashcards",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
            ]
        ),
        .testTarget(name: "FlashcardsTests", dependencies: [
            "Flashcards", .product(name: "EasyNotesCore", package: "EasyNotesCore"),
        ]),
    ]
)
