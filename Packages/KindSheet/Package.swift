// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindSheet",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KindSheet", targets: ["KindSheet"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
    ],
    targets: [
        .target(
            name: "KindSheet",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
            ],
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(name: "KindSheetTests", dependencies: [
            "KindSheet", .product(name: "EasyNotesCore", package: "EasyNotesCore"),
        ]),
    ]
)
