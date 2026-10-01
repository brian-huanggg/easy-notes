// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyNotesCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EasyNotesCore", targets: ["EasyNotesCore"]),
    ],
    targets: [
        .target(name: "EasyNotesCore"),
        .testTarget(name: "EasyNotesCoreTests", dependencies: ["EasyNotesCore"]),
    ]
)
