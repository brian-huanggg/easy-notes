// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindPDF",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KindPDF", targets: ["KindPDF"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
        .package(path: "../ExcalidrawKit"),
    ],
    targets: [
        .target(
            name: "KindPDF",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
                .product(name: "ExcalidrawKit", package: "ExcalidrawKit"),
            ],
            resources: [.process("Localizable.xcstrings")]
        ),
        .testTarget(name: "KindPDFTests", dependencies: [
            "KindPDF", .product(name: "EasyNotesCore", package: "EasyNotesCore"),
            .product(name: "ExcalidrawKit", package: "ExcalidrawKit"),
        ]),
    ]
)
