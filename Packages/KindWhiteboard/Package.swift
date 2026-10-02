// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KindWhiteboard",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "KindWhiteboard", targets: ["KindWhiteboard"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
        .package(path: "../ExcalidrawKit"),
    ],
    targets: [
        .target(
            name: "KindWhiteboard",
            dependencies: [
                .product(name: "EasyNotesCore", package: "EasyNotesCore"),
                .product(name: "EasyNotesUI", package: "EasyNotesCore"),
                .product(name: "ExcalidrawKit", package: "ExcalidrawKit"),
            ]
        ),
        .testTarget(name: "KindWhiteboardTests", dependencies: [
            "KindWhiteboard", .product(name: "EasyNotesCore", package: "EasyNotesCore"),
            .product(name: "ExcalidrawKit", package: "ExcalidrawKit"),
            .product(name: "EasyNotesUI", package: "EasyNotesCore"),
        ], resources: [.copy("Fixtures")]),
    ]
)
