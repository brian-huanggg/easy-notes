// swift-tools-version: 6.0
import PackageDescription

/// 白板與 PDF 標註共用的 Excalidraw 格式程式：元素模型、合併、筆畫轉換、渲染。
/// 不是外掛：不依賴 EasyNotesUI，也不依賴任何外掛。
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
