// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyNotesCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EasyNotesCore", targets: ["EasyNotesCore"]),
        .library(name: "EasyNotesUI", targets: ["EasyNotesUI"]),
    ],
    targets: [
        // 檔案、索引、同步與 KindRegistry；不認識任何檔案類型，沒有 UI 依賴
        .target(name: "EasyNotesCore"),
        // 外掛共用的 UI 層：PluginRegistry、DocumentSession、WebEditorHost
        .target(name: "EasyNotesUI", dependencies: ["EasyNotesCore"]),
        .testTarget(name: "EasyNotesCoreTests", dependencies: ["EasyNotesCore"]),
    ]
)
