import Foundation

/// E2E（XCUITest）的啟動參數；只在 DEBUG 生效，Release 一律是正常行為。
/// 參數名稱在 `LaunchKey`（UITestContract.swift，與測試 target 共用）。
enum TestHooks {
    enum Sync: Equatable {
        /// 正常：Supabase（Sign in with Apple）
        case supabase
        /// 不同步、不碰網路
        case off
        /// 以資料夾當遠端（`FolderSyncBackend`），測試程序扮演另一台裝置
        case folder(URL)
    }

    /// 測試指定的 Vault（每個測試一個暫存資料夾）
    static var vaultRoot: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: LaunchKey.vaultRoot).map { URL(filePath: $0, directoryHint: .isDirectory) }
        #else
        nil
        #endif
    }

    static var sync: Sync {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: LaunchKey.syncFolder) {
            return .folder(URL(filePath: folder, directoryHint: .isDirectory))
        }
        if UserDefaults.standard.string(forKey: LaunchKey.sync) == "off" { return .off }
        #endif
        return .supabase
    }

    /// UI 測試中：關閉動畫，等待條件更穩定
    static var isUITest: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: LaunchKey.uiTest)
        #else
        false
        #endif
    }
}
