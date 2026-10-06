import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// Design `C/Sidebar Desktop` (`YXFMc`): vault header, search, navigation, Spaces, Tags; at the bottom recently deleted, sync status, settings.
/// Plugin items (`addPanel`) follow All Documents; the app hardcodes no plugin.
struct Sidebar: View {
    @Environment(VaultStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @Environment(ShellState.self) private var shell
    /// Expanded folders (the Spaces file tree)
    @State private var expanded: Set<String> = []
    /// The path being renamed in place (Mac double-click)
    @State private var editing: String?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    /// The folder being dragged over (`""` = the "Spaces" header = root)
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VaultHeader(name: store.vaultName, account: sync.accountEmail, icon: Image("AppLogo"))
                        .padding(.bottom, 10)
                    SearchFieldButton(L("搜尋"), shortcut: "⌘K") { shell.showQuickOpen = true }
                        .accessibilityIdentifier(A11yID.Sidebar.search)
                        .padding(.bottom, 12)
                    navigation
                    spaces.padding(.top, 18)
                    if !store.tags.isEmpty { tags.padding(.top, 18) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            footer
        }
        .background(Palette.bgSidebar)
        .onChange(of: store.route) { _, route in reveal(route) }
    }

    // MARK: Navigation

    private var navigation: some View {
        VStack(spacing: 1) {
            item(.all, L("所有文件"), symbol: "doc.text", count: store.files.count)
                .accessibilityIdentifier(A11yID.Sidebar.all)
            ForEach(store.plugins.panels) { panel in
                item(.panel(panel.id), panel.title, symbol: panel.symbol, count: panel.badge(), countTint: panel.badgeTint)
                    .accessibilityIdentifier(A11yID.Sidebar.panel(panel.id))
            }
            item(.recents, L("最近"), symbol: "clock.arrow.circlepath")
                .accessibilityIdentifier(A11yID.Sidebar.recents)
            item(.pinned, L("已釘選"), symbol: "pin", count: pinnedCount)
                .accessibilityIdentifier(A11yID.Sidebar.pinned)
        }
    }

    private var pinnedCount: Int? {
        let count = store.files.count(where: \.pinned)
        return count > 0 ? count : nil
    }

    private func item(_ route: Route, _ title: String, symbol: String, count: Int? = nil,
                      countTint: ColorToken? = nil) -> some View {
        Button { store.navigate(route) } label: {
            SidebarItem(title, symbol: symbol, count: count, countTint: countTint, isSelected: store.route == route)
        }
        .buttonStyle(.plain)
    }

    // MARK: Spaces = first-level folders

    private var spaces: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarGroupLabel(L("空間"), actionSymbol: "plus", actionHelp: L("新增空間")) { store.createSpace() }
                .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                    .fill(dropTarget == "" ? Palette.bgSelected : ColorToken.clear))
                .dropDestination(for: String.self) { paths, _ in drop(paths, into: "") }
                    isTargeted: { setDropTarget("", $0) }
            ForEach(store.tree.filter(\.isFolder)) { folder in
                node(folder, depth: 0)
            }
        }
    }

    private func node(_ node: VaultNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            row(node, depth: depth)
            if node.isFolder, expanded.contains(node.path) {
                ForEach(node.children ?? []) { child in
                    self.node(child, depth: depth + 1)
                }
            }
        })
    }

    private func row(_ node: VaultNode, depth: Int) -> some View {
        let route: Route = node.isFolder ? .folder(node.path) : .file(node.path)
        let kind = store.kindID(node.path)
        let symbol = node.isFolder ? (expanded.contains(node.path) ? "folder.fill" : "folder")
                                   : store.plugins.symbol(for: kind)
        // Dropping onto a file = dropping into its containing folder
        let folder = node.isFolder ? node.path : (node.path as NSString).deletingLastPathComponent
        return Group {
            if editing == node.path {
                renameField(symbol: symbol, depth: depth)
            } else {
                Button { click(node) } label: {
                    SidebarItem(title(of: node), symbol: symbol,
                                symbolTint: node.isFolder ? nil : store.plugins.tint(for: kind).base,
                                count: node.isFolder && depth == 0 ? store.fileCount(in: node.path) : nil,
                                isSelected: store.route == route || (node.isFolder && dropTarget == node.path),
                                indent: depth)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Sidebar.node(node.path))
                .draggable(node.path)
            }
        }
        .contextMenu { NodeMenu(path: node.path, isFolder: node.isFolder) }
        .dropDestination(for: String.self) { paths, _ in drop(paths, into: folder) }
            isTargeted: { setDropTarget(folder, $0) }
    }

    private func title(of node: VaultNode) -> String {
        node.isFolder ? node.name : store.displayName(node.path)
    }

    // MARK: Rename in place

    /// The same layout as `SidebarItem` with the title replaced by a text field
    private func renameField(symbol: String, depth: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: depth > 0 ? 12 : 14))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16, height: 16)
            TextField(L("名稱"), text: $draftName)
                .textFieldStyle(.plain)
                .textStyle(depth > 0 ? .control : .sidebarItem)
                .foregroundStyle(Palette.textPrimary)
                .focused($nameFocused)
                .onSubmit(commitRename)
                #if os(macOS)
                .onExitCommand { editing = nil }
                #endif
                .onChange(of: nameFocused) { _, focused in if !focused { commitRename() } }
        }
        .padding(.vertical, depth > 0 ? 4 : 5.5)
        .padding(.leading, 9 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
            .fill(Palette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
            .strokeBorder(Palette.accent))
        .onAppear { nameFocused = true }
    }

    private func startRename(_ node: VaultNode) {
        draftName = title(of: node)
        editing = node.path
    }

    /// Called on Return and on losing focus; Esc clears `editing` first, so losing focus afterwards does not rename again
    private func commitRename() {
        guard let path = editing else { return }
        editing = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = store.isFolder(path) ? (path as NSString).lastPathComponent : store.displayName(path)
        guard !name.isEmpty, name != current else { return }
        Task { await store.rename(path, to: name) }
    }

    // MARK: Drag to move

    private func setDropTarget(_ folder: String, _ targeted: Bool) {
        if targeted { dropTarget = folder } else if dropTarget == folder { dropTarget = nil }
    }

    /// Accepts only paths that exist in the vault (dragged content may also be plain text)
    private func drop(_ paths: [String], into folder: String) -> Bool {
        let moves = paths.filter { $0 != folder && store.vault.exists($0) }
        guard !moves.isEmpty else { return false }
        if !folder.isEmpty { expanded.insert(folder) }
        Task { for path in moves { await store.move(path, toFolder: folder) } }
        return true
    }

    /// Mac double-click renames; a single click opens as usual (the first click of a double-click already opened it)
    private func click(_ node: VaultNode) {
        #if os(macOS)
        if NSApp.currentEvent?.clickCount == 2 { return startRename(node) }
        #endif
        open(node)
    }

    /// Clicking a folder: opens the folder page and expands it; clicking the selected folder again collapses it
    private func open(_ node: VaultNode) {
        guard node.isFolder else { return store.navigate(.file(node.path)) }
        if store.route == .folder(node.path) {
            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
        } else {
            expanded.insert(node.path)
            store.navigate(.folder(node.path))
        }
    }

    /// A file opened from elsewhere (⌘K, a link, back): expands its containing folder
    private func reveal(_ route: Route) {
        guard case .file(let path) = route else { return }
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    // MARK: Tags

    private var tags: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarGroupLabel(L("標籤"))
            ForEach(store.tags) { tag in
                item(.tag(tag.tag), tag.tag, symbol: "number", count: tag.count)
            }
        }
    }

    // MARK: Bottom

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { shell.showRecentlyDeleted = true } label: {
                StatusRow(L("最近刪除"), detail: L("保留 \(SyncEngine.retentionDays) 天"), symbol: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Sidebar.recentlyDeleted)
            SyncStatusRow()
            SettingsButton()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Settings: macOS opens the Settings window, iOS shows a sheet
private struct SettingsButton: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        #if os(macOS)
        SettingsLink { label }.buttonStyle(.plain)
        #else
        Button { shell.showSettings = true } label: { label }.buttonStyle(.plain)
        #endif
    }

    private var label: some View {
        SidebarItem(L("設定"), symbol: "gearshape")
    }
}

/// Context menu for files and folders: rename, reveal in Finder, move to trash, delete immediately
struct NodeMenu: View {
    @Environment(VaultStore.self) private var store
    @Environment(ShellState.self) private var shell
    let path: String
    let isFolder: Bool

    var body: some View {
        Button(L("重新命名"), systemImage: "pencil") {
            shell.rename(path, current: isFolder ? (path as NSString).lastPathComponent : store.displayName(path))
        }
        .accessibilityIdentifier(A11yID.Menu.rename)
        if !isFolder, let file = store.file(at: path), store.fs.kinds.kind(for: path)?.supportsPinning == true {
            Button(file.pinned ? L("取消釘選") : L("釘選"), systemImage: file.pinned ? "pin.slash" : "pin") {
                Task { await store.setPinned(path, !file.pinned) }
            }
            .accessibilityIdentifier(A11yID.Menu.pin)
        }
        Button(revealTitle, systemImage: "folder") { reveal(store.fs.url(for: path)) }
            .accessibilityIdentifier(A11yID.Menu.reveal)
        Divider()
        Button(L("移到垃圾桶"), systemImage: "trash", role: .destructive) {
            Task { await store.delete(path) }
        }
        .accessibilityIdentifier(A11yID.Menu.trash)
        Button(L("立即刪除"), systemImage: "trash.slash", role: .destructive) {
            shell.purging = .init(path: path, isFolder: isFolder)
        }
        .accessibilityIdentifier(A11yID.Menu.deleteImmediately)
    }
}
