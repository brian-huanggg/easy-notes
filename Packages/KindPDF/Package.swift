// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindPDF",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KindPDF", targets: ["KindPDF"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
    ],
    targets: [
        .target(
            name: "KindPDF",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
            ]
        ),
    ]
)
