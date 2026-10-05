// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyNotesCore",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EasyNotesCore", targets: ["EasyNotesCore"]),
        .library(name: "EasyNotesUI", targets: ["EasyNotesUI"]),
        .library(name: "EasyNotesTestSupport", targets: ["EasyNotesTestSupport"]),
    ],
    targets: [
        // Files, index, sync and KindRegistry; knows no file types, no UI dependency
        .target(name: "EasyNotesCore", resources: [.process("Localizable.xcstrings")]),
        // The UI layer shared by plugins: PluginRegistry, DocumentSession, WebEditorHost
        .target(name: "EasyNotesUI", dependencies: ["EasyNotesCore"], resources: [.process("Localizable.xcstrings")]),
        // For E2E: a SyncBackend using a folder as the remote (the app uses it only in DEBUG test mode)
        .target(name: "EasyNotesTestSupport", dependencies: ["EasyNotesCore"]),
        .testTarget(name: "EasyNotesCoreTests", dependencies: ["EasyNotesCore", "EasyNotesTestSupport"]),
        .testTarget(name: "EasyNotesUITests", dependencies: ["EasyNotesUI"]),
    ]
)
