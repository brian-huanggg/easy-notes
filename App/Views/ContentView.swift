import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// The shell. iPhone (compact width) uses bottom tabs; Mac and iPad use sidebar + content area.
/// Cross-screen UI such as ⌘K, import, recently deleted and rename hangs here
struct ContentView: View {
    @Environment(VaultStore.self) private var store
    @Environment(ShellState.self) private var shell
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var shell = shell
        layout
            .tint(Palette.accent.color)
            .sheet(isPresented: $shell.showQuickOpen) {
                QuickOpen()
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(isPresented: $shell.showRecentlyDeleted) { RecentlyDeletedView() }
            .sheet(isPresented: $shell.showSettings) { NavigationStack { MeView() } }
            .sheet(item: $shell.whatsNew) { WhatsNewView(notes: $0) }
            .task {
                // The E2E view must not be covered by the window
                guard !TestHooks.isUITest else { return }
                shell.whatsNew = WhatsNew.pendingOnLaunch(isFreshInstall: store.isFreshInstall)
            }
            .fileImporter(isPresented: $shell.isImporting, allowedContentTypes: shell.importTypes,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { for url in urls { await store.importFile(url) } }
            }
            .confirmationDialog(L("立即刪除？"), isPresented: Binding(get: { shell.purging != nil },
                                                                  set: { if !$0 { shell.purging = nil } }),
                                titleVisibility: .visible, presenting: shell.purging) { request in
                Button(L("立即刪除"), role: .destructive) {
                    Task { await store.deleteImmediately(request.path) }
                }
                .accessibilityIdentifier(A11yID.Menu.confirmDeleteImmediately)
                Button(L("取消"), role: .cancel) {}
            } message: { request in
                Text(request.isFolder
                     ? L("資料夾和裡面的所有檔案會永久刪除，不會進入「最近刪除」，也無法復原。其他裝置上的也會一併刪除。")
                     : L("「\(store.displayName(request.path))」會永久刪除，不會進入「最近刪除」，也無法復原。其他裝置上的也會一併刪除。"))
            }
            .alert(L("重新命名"), isPresented: Binding(get: { shell.renaming != nil },
                                                set: { if !$0 { shell.renaming = nil } })) {
                TextField(L("名稱"), text: $shell.newName)
                    .accessibilityIdentifier(A11yID.Rename.field)
                Button(L("取消"), role: .cancel) { shell.renaming = nil }
                Button(L("確定")) {
                    if let path = shell.renaming {
                        let name = shell.newName
                        Task { await store.rename(path, to: name) }
                    }
                    shell.renaming = nil
                }
                .accessibilityIdentifier(A11yID.Rename.confirm)
            } message: {
                Text(L("其他筆記中指向它的 [[連結]] 會一併更新。"))
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if sizeClass == .compact { PhoneShell() } else { SplitShell() }
        #else
        SplitShell()
        #endif
    }
}

// MARK: - Mac / iPad

struct SplitShell: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: Metrics.sidebarWidth, max: 340)
                #if os(macOS)
                .toolbar(removing: .sidebarToggle)
                #endif
        } detail: {
            VStack(spacing: 0) {
                if store.tabs.tabs.count > 1 { DocumentTabBar() }
                ShellDetail(route: store.route)
            }
                .inspector(isPresented: Binding(get: { store.sidePath != nil },
                                                set: { if !$0 { store.sidePath = nil } })) {
                    SidePanel()
                        .inspectorColumnWidth(min: 320, ideal: 440, max: 720)
                }
        }
        .onAppear {
            store.supportsSide = true
            store.enableTabs()
        }
        .onDisappear {
            store.supportsSide = false
            store.supportsTabs = false
        }
    }
}

/// Side panel: a whiteboard's note card opens a full editor beside the main content (independent of it)
struct SidePanel: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        if let path = store.sidePath {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: store.symbol(for: .file(path)))
                    Text(store.title(for: .file(path))).lineLimit(1)
                    Spacer()
                    Button(L("在主視窗開啟"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        store.sidePath = nil
                        store.open(path, line: nil)
                    }
                    .labelStyle(.iconOnly)
                    Button(L("關閉"), systemImage: "xmark") { store.sidePath = nil }
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if let editor = store.plugins.editor(for: store.kindID(path), path: path) {
                    editor.id(path)
                } else {
                    ContentUnavailableView(L("不支援的檔案類型"), systemImage: "doc.questionmark")
                }
            }
            .background(Palette.bgCanvas)
        }
    }
}

/// Content area: shows a list page, editor or plugin panel for the current location, with a consistent toolbar
struct ShellDetail: View {
    @Environment(VaultStore.self) private var store
    let route: Route

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bgCanvas)
            .navigationTitle(store.title(for: route))
            #if os(macOS)
            .toolbar(removing: .title)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ShellToolbar(route: route) }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .file(let path):
            editor(for: path)
                // The container itself becomes an element (without covering children's identifiers); E2E uses it to confirm the editor has opened
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.Editor.container(store.kindID(path) ?? "none"))
        case .panel(let id):
            if let panel = store.plugins.panel(id: id) {
                panel.content()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(A11yID.panel(id))
            }
        default:
            DocumentList(route: route)
        }
    }

    /// Editors are registered by each plugin with PluginRegistry
    @ViewBuilder
    private func editor(for path: String) -> some View {
        if let editor = store.plugins.editor(for: store.kindID(path), path: path) {
            editor
        } else {
            ContentUnavailableView(L("不支援的檔案類型"), systemImage: "doc.questionmark")
                .accessibilityIdentifier(A11yID.Editor.unsupported)
        }
    }
}

/// Toolbar: back / forward, breadcrumb, grid / list, sort, reveal in Finder, New Document
struct ShellToolbar: ToolbarContent {
    @Environment(VaultStore.self) private var store
    @AppStorage("listLayout") private var layout = ListLayout.grid
    @AppStorage("listSort") private var sort = ListSort.modified
    let route: Route

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(L("上一頁"), systemImage: "chevron.left") { store.goBack() }
                .disabled(store.backStack.isEmpty)
                .help(L("上一頁（⌘[）"))
                .accessibilityIdentifier(A11yID.Toolbar.back)
            Button(L("下一頁"), systemImage: "chevron.right") { store.goForward() }
                .disabled(store.forwardStack.isEmpty)
                .help(L("下一頁（⌘]）"))
                .accessibilityIdentifier(A11yID.Toolbar.forward)
        }
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 4) {
                Breadcrumb(symbol: store.symbol(for: route), store.breadcrumb(for: route))
                if let path = route.filePath { DocumentStatusPill(path: path) }
            }
            .fixedSize()
        }
        .withoutSharedBackground()
        #if os(macOS)
        FlexibleToolbarSpace()
        #endif
        if isList {
            // The segmented control has its own background, so it is not put in the toolbar's shared glass background (otherwise the edge shows white)
            ToolbarItem(placement: Self.trailing) {
                IconSegmentedControl(selection: $layout, segments: [
                    .init(.grid, symbol: "square.grid.2x2", help: L("網格")),
                    .init(.list, symbol: "list.bullet", help: L("列表")),
                ])
            }
            .withoutSharedBackground()
        }
        if let path = route.filePath {
            // Editor: pin, more (reveal in Finder, copy path, open with another app…)
            ToolbarItemGroup(placement: Self.trailing) {
                PinButton(path: path)
                DocumentMoreMenu(path: path)
            }
        } else {
            listTrailingItems
        }
    }

    @ToolbarContentBuilder
    private var listTrailingItems: some ToolbarContent {
        ToolbarItemGroup(placement: Self.trailing) {
            if isList {
                Picker(selection: $sort) {
                    Text(L("最近編輯")).tag(ListSort.modified)
                    Text(L("名稱")).tag(ListSort.name)
                } label: {
                    Label(L("排序"), systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                .help(L("排序"))
                .disabled(route == .recents)
            }
            if let url = revealURL {
                Button(revealTitle, systemImage: "folder") { reveal(url) }
                    .help(revealTitle)
            }
            NewDocumentMenu()
        }
    }

    /// On macOS `.primaryAction` is at the leading edge; this group of buttons is at the trailing end in the design
    #if os(macOS)
    private static let trailing = ToolbarItemPlacement.automatic
    #else
    private static let trailing = ToolbarItemPlacement.primaryAction
    #endif

    private var isList: Bool {
        switch route {
        case .file, .panel: false
        default: true
        }
    }

    /// Folder → that folder; other list pages → vault root (a file's "Reveal in Finder" is in the more menu)
    private var revealURL: URL? {
        switch route {
        case .file: nil
        case .folder(let path): store.fs.url(for: path)
        case .panel: nil
        default: store.fs.root
        }
    }
}

/// The design's New Document menu: new file (`addNewFile`), import (`addImport`), new folder
struct NewDocumentMenu: View {
    @Environment(VaultStore.self) private var store
    @Environment(ShellState.self) private var shell

    var body: some View {
        Menu {
            NewDocumentItems(store: store, shell: shell)
        } label: {
            Label(L("新增文件"), systemImage: "plus")
        } primaryAction: {
            if let command = store.plugins.newFileCommands.first {
                store.create(command.kind, title: command.defaultName)
            }
        }
        .help(L("新增文件"))
        .accessibilityIdentifier(A11yID.Toolbar.newDocument)
    }
}

/// Items of the New Document menu; shared by the toolbar menu and the app's "File" menu (Commands cannot get the environment, so it is passed explicitly)
struct NewDocumentItems: View {
    let store: VaultStore
    let shell: ShellState

    var body: some View {
        ForEach(store.plugins.newFileCommands) { command in
            Button(command.title, systemImage: command.symbol) {
                store.create(command.kind, title: command.defaultName)
            }
            .keyboardShortcut(command.shortcut)
        }
        if !store.plugins.importCommands.isEmpty {
            Divider()
            ForEach(store.plugins.importCommands) { command in
                Button(command.title, systemImage: command.symbol) { shell.startImport(command) }
                    .keyboardShortcut(command.shortcut)
            }
        }
        Divider()
        Button(L("新資料夾"), systemImage: "folder.badge.plus") { store.createFolder() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}

private extension ToolbarContent {
    /// From macOS / iOS 26, items in the same position share one glass background; the breadcrumb is text and gets none
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, iOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

#if os(macOS)
/// Pushes the following items to the end of the toolbar (from macOS 26 `.automatic` follows right after leading items)
private struct FlexibleToolbarSpace: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        }
    }
}
#endif
