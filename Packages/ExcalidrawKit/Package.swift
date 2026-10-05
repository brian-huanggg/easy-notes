// swift-tools-version: 6.0
import PackageDescription

/// Excalidraw format code shared by whiteboard and PDF annotation: element model, merge, stroke conversion, rendering.
/// Not a plugin: depends on neither EasyNotesUI nor any plugin.
let package = Package(
    name: "ExcalidrawKit",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ExcalidrawKit", targets: ["ExcalidrawKit"]),
    ],
    targets: [
        .target(name: "ExcalidrawKit", resources: [.process("Localizable.xcstrings")]),
    ]
)
