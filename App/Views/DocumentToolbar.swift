import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 編輯器工具列的元件（所有檔案類型共用）：儲存 / 同步狀態、釘選、更多選單

/// 麵包屑旁的「已儲存」膠囊：顯示這份文件的儲存與同步狀態
struct DocumentStatusPill: View {
    @Environment(SyncCoordinator.self) private var sync
    @Environment(VaultStore.self) private var store
    let path: String

    var body: some View {
        let (title, symbol) = status
        Pill(title, symbol: symbol)
            .help(sync.statusTitle)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11yID.Toolbar.status)
    }

    /// 編輯內容由編輯器自動存檔，所以本地一律是「已儲存」；登入後再區分同步中與衝突
    private var status: (String, String) {
        guard case .signedIn = sync.account else { return (L("已儲存"), "checkmark") }
        let stem = store.displayName(path)
        if sync.conflicts.contains(where: { SyncEngine.isConflictCopy(store.displayName($0), of: stem) }) {
            return (L("有衝突副本"), "exclamationmark.triangle")
        }
        if sync.status.isSyncing || sync.status.pending > 0 { return (L("同步中"), "arrow.triangle.2.circlepath") }
        return (L("已儲存"), "checkmark.icloud")
    }
}

/// 釘選按鈕；只對支援釘選的類型顯示（`DocumentKind.supportsPinning`）
struct PinButton: View {
    @Environment(VaultStore.self) private var store
    let path: String

    var body: some View {
        if store.fs.kinds.kind(for: path)?.supportsPinning == true {
            let pinned = store.file(at: path)?.pinned ?? false
            Button(pinned ? L("取消釘選") : L("釘選"), systemImage: pinned ? "pin.fill" : "pin") {
                Task { await store.setPinned(path, !pinned) }
            }
            .tint(pinned ? Palette.yellow.color : nil)
            .help(pinned ? L("取消釘選") : L("釘選"))
            .accessibilityIdentifier(A11yID.Toolbar.pin)
        }
    }
}

/// 更多選單：在 Finder 中顯示、複製路徑、用其他 App 開啟、重新命名、移到垃圾桶
struct DocumentMoreMenu: View {
    @Environment(VaultStore.self) private var store
    @Environment(ShellState.self) private var shell
    let path: String

    var body: some View {
        Menu(L("更多"), systemImage: "ellipsis") {
            let url = store.fs.url(for: path)
            Button(revealTitle, systemImage: "folder") { reveal(url) }
            Button(L("複製路徑"), systemImage: "doc.on.doc") { copyToPasteboard(url.path(percentEncoded: false)) }
                .accessibilityIdentifier(A11yID.Menu.copyPath)
            #if os(macOS)
            OpenWithMenu(url: url)
            #endif
            Divider()
            Button(L("重新命名"), systemImage: "pencil") { shell.rename(path, current: store.displayName(path)) }
                .accessibilityIdentifier(A11yID.Menu.rename)
            Button(L("移到垃圾桶"), systemImage: "trash", role: .destructive) {
                Task { await store.delete(path) }
            }
            .accessibilityIdentifier(A11yID.Menu.trash)
        }
        .help(L("更多"))
        .accessibilityIdentifier(A11yID.Toolbar.more)
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

#if os(macOS)
/// 用其他 App 開啟：列出系統中能開這個檔案的 App，預設 App 在最上面
private struct OpenWithMenu: View {
    let url: URL

    var body: some View {
        Menu(L("用其他 App 開啟"), systemImage: "arrow.up.forward.app") {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
                .filter { $0.lastPathComponent != Bundle.main.bundleURL.lastPathComponent }
            ForEach(apps, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path(percentEncoded: false))) {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }
}
#endif
