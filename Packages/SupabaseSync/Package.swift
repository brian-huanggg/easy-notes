// swift-tools-version: 6.0
import PackageDescription

/// SyncBackend 的 Supabase 實作。不是外掛：Core 的同步引擎透過它連到網路，App 負責組裝。
let package = Package(
    name: "SupabaseSync",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SupabaseSync", targets: ["SupabaseSync"]),
    ],
    dependencies: [
        .package(path: "../EasyNotesCore"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0"),
    ],
    targets: [
        .target(name: "SupabaseSync", dependencies: [
            .product(name: "EasyNotesCore", package: "EasyNotesCore"),
            .product(name: "Supabase", package: "supabase-swift"),
        ]),
        // 整合測試：需要本地 Supabase（scripts/test-sync.sh 會設定環境變數）
        .testTarget(name: "SupabaseSyncTests", dependencies: ["SupabaseSync"]),
    ]
)
