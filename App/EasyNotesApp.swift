import EasyNotesCore
import EasyNotesUI
import KindMarkdown
import KindWhiteboard
import SwiftUI

/// 編譯期組裝的外掛，依序註冊。第一個是預設類型（`[[連結]]` 找不到時建立）。
private let plugins: [any EasyNotesPlugin.Type] = [
    MarkdownPlugin.self,
    WhiteboardPlugin.self,
]

@main
struct EasyNotesApp: App {
    @State private var store: VaultStore
    @State private var sync: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let registry = PluginRegistry()
        for plugin in plugins { plugin.register(in: registry) }
        let kinds: KindRegistry
        do { kinds = try registry.makeKinds() } catch { fatalError("外掛註冊衝突：\(error)") }
        let store = VaultStore(plugins: registry, kinds: kinds)
        _store = State(initialValue: store)
        _sync = State(initialValue: SyncCoordinator(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(sync)
                .environment(\.documentSession, store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.syncIndex() } // 在「檔案」App 改過的檔案
                sync.scenePhaseChanged(active: true)
            } else {
                Task {
                    await store.flushEditors()
                    sync.scenePhaseChanged(active: false)
                }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                ForEach(store.plugins.newFileCommands) { command in
                    Button(command.title) { store.create(command.kind, title: command.defaultName) }
                        .keyboardShortcut(command.shortcut)
                }
            }
            PluginMenus(menus: store.plugins.menus)
        }
    }
}

/// 外掛註冊的頂層選單。SwiftUI 的 Commands 不能用 ForEach，所以預留固定數量的位置。
private struct PluginMenus: Commands {
    let menus: [PluginRegistry.Menu]

    var body: some Commands {
        if menus.count > 0 { PluginMenu(menu: menus[0]) }
        if menus.count > 1 { PluginMenu(menu: menus[1]) }
        if menus.count > 2 { PluginMenu(menu: menus[2]) }
        if menus.count > 3 { PluginMenu(menu: menus[3]) }
    }
}

private struct PluginMenu: Commands {
    let menu: PluginRegistry.Menu

    var body: some Commands {
        CommandMenu(menu.title) {
            ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section) { item in
                    Button(item.title, action: item.action)
                        .keyboardShortcut(item.shortcut)
                }
            }
        }
    }
}
