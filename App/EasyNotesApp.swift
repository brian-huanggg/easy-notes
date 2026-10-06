import AppUpdater
import EasyNotesCore
import EasyNotesUI
import Flashcards
import KindMarkdown
import KindPDF
import KindSheet
import KindWhiteboard
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Plugins assembled at compile time, registered in order. The first is the default kind (created when a `[[link]]` is not found).
private let plugins: [any EasyNotesPlugin.Type] = [
    MarkdownPlugin.self,
    WhiteboardPlugin.self,
    PDFPlugin.self,
    SheetPlugin.self,
    FlashcardsPlugin.self,
]

@main
struct EasyNotesApp: App {
    @State private var store: VaultStore
    @State private var sync: SyncCoordinator
    @State private var shell = ShellState()
    @State private var updater = AppUpdater(enabled: !TestHooks.isUITest)
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.system

    init() {
        #if os(iOS)
        if TestHooks.isUITest { UIView.setAnimationsEnabled(false) }
        #endif
        Diagnostics.start()
        let registry = PluginRegistry()
        for plugin in plugins { plugin.register(in: registry) }
        let kinds: KindRegistry
        do { kinds = try registry.makeKinds() } catch { fatalError("外掛註冊衝突：\(error)") }
        let store = VaultStore(plugins: registry, kinds: kinds)
        _store = State(initialValue: store)
        _sync = State(initialValue: SyncCoordinator(store: store))
    }

    /// ⌘W: closes the current tab; with only one tab left it closes the window (macOS).
    private func closeTabOrWindow() {
        #if os(macOS)
        if store.tabs.tabs.count <= 1 {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        #endif
        store.closeTab(store.tabs.activeID)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(sync)
                .environment(shell)
                .environment(\.documentSession, store)
                .appTheme(theme)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.scanLocalChanges() } // Files changed in the Files app
                sync.scenePhaseChanged(active: true)
            } else {
                Task {
                    await store.flushEditors()
                    sync.scenePhaseChanged(active: false)
                }
            }
        }
        .commands {
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                Button(L("檢查更新…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            #endif
            CommandGroup(after: .help) {
                Button(L("版本新功能…")) { shell.whatsNew = WhatsNew.bundled() }
                    .disabled(WhatsNew.bundled() == nil)
            }
            CommandGroup(replacing: .newItem) {
                NewDocumentItems(store: store, shell: shell)
                Divider()
                Button(L("新分頁")) { store.newTab() }
                    .shortcut(.newTab)
                    .disabled(!store.supportsTabs)
                Button(L("關閉分頁")) { closeTabOrWindow() }
                    .shortcut(.closeTab)
                    .disabled(!store.supportsTabs)
                #if os(macOS)
                Button(L("關閉視窗")) { NSApp.keyWindow?.performClose(nil) }
                    .shortcut(.closeWindow)
                #endif
                Divider()
                Button(L("立即同步")) { sync.syncNow() }
                    .shortcut(.syncNow)
            }
            CommandMenu(L("前往")) {
                Button(L("快速開啟…")) { shell.showQuickOpen = true }
                    .shortcut(.quickOpen)
                Divider()
                Button(L("上一頁")) { store.goBack() }
                    .shortcut(.back)
                    .disabled(store.backStack.isEmpty)
                Button(L("下一頁")) { store.goForward() }
                    .shortcut(.forward)
                    .disabled(store.forwardStack.isEmpty)
                Divider()
                Button(L("下一個分頁")) { store.cycleTab(1) }
                    .shortcut(.nextTab)
                    .disabled(!store.supportsTabs)
                Button(L("上一個分頁")) { store.cycleTab(-1) }
                    .shortcut(.previousTab)
                    .disabled(!store.supportsTabs)
                Divider()
                Button(L("所有文件")) { store.navigate(.all) }
                Button(L("最近")) { store.navigate(.recents) }
            }
            PluginMenus(menus: store.plugins.menus)
        }

        #if os(macOS)
        Settings {
            MeView()
                .environment(store)
                .environment(sync)
                .appTheme(theme)
        }
        #endif
    }
}

/// Top-level menus registered by plugins. SwiftUI Commands cannot use ForEach, so a fixed number of slots is reserved.
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
