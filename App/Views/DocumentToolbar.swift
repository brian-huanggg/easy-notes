import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// Editor toolbar components (shared by all file types): save / sync status, pin, more menu

/// The "Saved" capsule beside the breadcrumb: shows this document's save and sync status
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

    /// Editing is auto-saved by the editor, so locally it is always "Saved"; after sign-in it distinguishes syncing from conflict
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

/// Pin button; shown only for types that support pinning (`DocumentKind.supportsPinning`)
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

/// More menu: reveal in Finder, copy path, open with another app, rename, move to trash, delete immediately
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
            Button(L("立即刪除"), systemImage: "trash.slash", role: .destructive) {
                shell.purging = .init(path: path, isFolder: false)
            }
            .accessibilityIdentifier(A11yID.Menu.deleteImmediately)
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
/// Open with another app: lists the apps on the system that can open this file, with the default app on top
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
