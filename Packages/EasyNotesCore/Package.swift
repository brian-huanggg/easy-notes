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
        // 檔案、索引、同步與 KindRegistry；不認識任何檔案類型，沒有 UI 依賴
        .target(name: "EasyNotesCore", resources: [.process("Localizable.xcstrings")]),
        // 外掛共用的 UI 層：PluginRegistry、DocumentSession、WebEditorHost
        .target(name: "EasyNotesUI", dependencies: ["EasyNotesCore"], resources: [.process("Localizable.xcstrings")]),
        // E2E 測試用：以資料夾當遠端的 SyncBackend（App 只在 DEBUG 的測試模式使用）
        .target(name: "EasyNotesTestSupport", dependencies: ["EasyNotesCore"]),
        .testTarget(name: "EasyNotesCoreTests", dependencies: ["EasyNotesCore", "EasyNotesTestSupport"]),
        .testTarget(name: "EasyNotesUITests", dependencies: ["EasyNotesUI"]),
    ]
)
