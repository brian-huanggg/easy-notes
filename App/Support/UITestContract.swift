// Contract shared by the app and the E2E test target (Tests/E2E): launch arguments and accessibility identifiers (see project.yml).
// Both sides compile the same file, so a rename cannot change only one side.

/// Launch argument names for E2E (UserDefaults argument domain: `-EasyNotesVaultRoot <path>`); effective only in DEBUG
enum LaunchKey {
    /// The vault folder for the test
    static let vaultRoot = "EasyNotesVaultRoot"
    /// `off`: no sync, no network
    static let sync = "EasyNotesSync"
    /// Uses this folder as the remote (FolderSyncBackend), with the test process playing another device
    static let syncFolder = "EasyNotesSyncFolder"
    /// `YES`: in a UI test (animations off)
    static let uiTest = "EasyNotesUITest"
    /// The file to open after launch (vault-relative path)
    static let open = "EasyNotesOpen"
}

/// Accessibility identifiers for UI tests. Tests find elements by identifier only, never by UI text, so translation or rewording cannot break them.
/// An identifier that contains a vault path carries the path directly (for example `sidebar.node:Projects/a.md`).
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
        /// A tab's location: a file carries its vault-relative path, others are `all`, `recents`…
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
        static let deleteImmediately = "menu.deleteImmediately"
        static let confirmDeleteImmediately = "menu.deleteImmediately.confirm"
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
        /// The editor container of the content area; `kindID` is the DocumentKind.id (markdown, ink, pdf, csv…)
        static func container(_ kindID: String) -> String { "editor:\(kindID)" }
        static let unsupported = "editor.unsupported"
    }

    /// The content container of a plugin panel (`addPanel`)
    static func panel(_ id: String) -> String { "panel:\(id)" }
}
