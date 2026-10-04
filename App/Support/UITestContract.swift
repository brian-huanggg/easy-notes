// App 與 E2E 測試 target（Tests/E2E）共用的約定：啟動參數與 accessibility identifier（見 project.yml）。
// 兩邊編譯同一份檔案，所以改名不會只改到一邊。

/// E2E 的啟動參數名稱（UserDefaults 的 argument domain：`-EasyNotesVaultRoot <路徑>`）；只在 DEBUG 生效
enum LaunchKey {
    /// 測試用的 Vault 資料夾
    static let vaultRoot = "EasyNotesVaultRoot"
    /// `off`：不同步、不碰網路
    static let sync = "EasyNotesSync"
    /// 以這個資料夾當遠端（FolderSyncBackend），測試程序扮演另一台裝置
    static let syncFolder = "EasyNotesSyncFolder"
    /// `YES`：UI 測試中（關閉動畫）
    static let uiTest = "EasyNotesUITest"
    /// 啟動後開啟的檔案（Vault 相對路徑）
    static let open = "EasyNotesOpen"
}

/// UI 測試用的 accessibility identifier。測試只用 identifier 找元素，不用介面文字，所以翻譯或改字不會讓測試壞掉。
/// 含 Vault 路徑的 identifier 直接帶路徑（例如 `sidebar.node:Projects/a.md`）。
enum A11yID {
    enum Sidebar {
        static let all = "sidebar.all"
        static let recents = "sidebar.recents"
        static let pinned = "sidebar.pinned"
        static let search = "sidebar.search"
        static let recentlyDeleted = "sidebar.recentlyDeleted"
        static let sync = "sidebar.sync"
        static func panel(_ id: String) -> String { "sidebar.panel:\(id)" }
        static func node(_ path: String) -> String { "sidebar.node:\(path)" }
    }

    enum List {
        static let title = "list.title"
        static let subtitle = "list.subtitle"
        static let filterAll = "list.filter.all"
        static func filter(_ kindID: String) -> String { "list.filter:\(kindID)" }
        static func document(_ path: String) -> String { "list.doc:\(path)" }
        static func folder(_ path: String) -> String { "list.folder:\(path)" }
    }

    enum Tabs {
        static let bar = "tabs.bar"
        static let new = "tabs.new"
        /// 分頁的位置：檔案帶 Vault 相對路徑，其他為 `all`、`recents`…
        static func tab(_ key: String) -> String { "tabs.tab:\(key)" }
        static func close(_ key: String) -> String { "tabs.close:\(key)" }
    }

    enum Toolbar {
        static let back = "toolbar.back"
        static let forward = "toolbar.forward"
        static let newDocument = "toolbar.newDocument"
        static let pin = "toolbar.pin"
        static let more = "toolbar.more"
        static let status = "toolbar.status"
    }

    enum Menu {
        static let rename = "menu.rename"
        static let pin = "menu.pin"
        static let reveal = "menu.reveal"
        static let trash = "menu.trash"
        static let copyPath = "menu.copyPath"
    }

    enum Rename {
        static let field = "rename.field"
        static let confirm = "rename.confirm"
    }

    enum QuickOpen {
        static let field = "quickOpen.field"
        static func hit(_ path: String) -> String { "quickOpen.hit:\(path)" }
    }

    enum Editor {
        /// 內容區的編輯器容器，`kindID` 是 DocumentKind.id（markdown、ink、pdf、csv…）
        static func container(_ kindID: String) -> String { "editor:\(kindID)" }
        static let unsupported = "editor.unsupported"
    }

    /// 外掛面板（`addPanel`）的內容容器
    static func panel(_ id: String) -> String { "panel:\(id)" }
}
