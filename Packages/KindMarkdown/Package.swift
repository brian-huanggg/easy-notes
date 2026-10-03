// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindMarkdown",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KindMarkdown", targets: ["KindMarkdown"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
    ],
    targets: [
        .target(
            name: "KindMarkdown",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
            ],
            // CodeMirror 6 bundle：由 web/ 的 `npm run build` 產生 editor.js
            resources: [.copy("Resources/Editor"), .process("Localizable.xcstrings")]
        ),
        .testTarget(name: "KindMarkdownTests", dependencies: [
            "KindMarkdown", .product(name: "EasyNotesCore", package: "EasyNotesCore"),
        ]),
    ]
)
