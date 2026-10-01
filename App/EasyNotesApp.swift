import EasyNotesCore
import SwiftUI

@main
struct EasyNotesApp: App {
    @State private var store: VaultStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = VaultStore()
        _store = State(initialValue: store)
        // 啟動時就預先載入編輯器 WebView，打開第一篇筆記時不會卡頓
        let host = WebEditorHost.shared
        host.onChanged = { [weak store] id, text in
            store?.write(Data(text.utf8), to: id)
        }
        host.onOpenLink = { [weak store] target in
            store?.openLink(target)
        }
        host.onOpenTag = { [weak store] tag in
            store?.searchText = "#" + tag
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.syncIndex() } // 在「檔案」App 或其他裝置改過的檔案
            } else {
                Task { await WebEditorHost.shared.flush() }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("新筆記") { store.create(MarkdownKind.self, title: "未命名") }
                    .keyboardShortcut("n")
                Button("新手寫") { store.create(InkKind.self, title: "手寫") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("格式") {
                // ⌘B / ⌘I 由 CodeMirror keymap 處理，這裡只提供選單入口
                Button("標題") { WebEditorHost.shared.exec("heading") }
                Button("粗體") { WebEditorHost.shared.exec("bold") }
                Button("斜體") { WebEditorHost.shared.exec("italic") }
                Button("行內程式碼") { WebEditorHost.shared.exec("code") }
                Divider()
                Button("項目清單") { WebEditorHost.shared.exec("bullet") }
                Button("待辦事項") { WebEditorHost.shared.exec("task") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("[[連結]]") { WebEditorHost.shared.exec("link") }
                    .keyboardShortcut("k")
            }
        }
    }
}
