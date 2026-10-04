import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 外殼。iPhone（compact 寬度）用底部分頁；Mac 與 iPad 用側邊欄 + 內容區。
/// ⌘K、匯入、最近刪除、重新命名等跨畫面的 UI 都掛在這裡
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
            .fileImporter(isPresented: $shell.isImporting, allowedContentTypes: shell.importTypes,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { for url in urls { await store.importFile(url) } }
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
            ShellDetail(route: store.route)
                .inspector(isPresented: Binding(get: { store.sidePath != nil },
                                                set: { if !$0 { store.sidePath = nil } })) {
                    SidePanel()
                        .inspectorColumnWidth(min: 320, ideal: 440, max: 720)
                }
        }
        .onAppear { store.supportsSide = true }
        .onDisappear { store.supportsSide = false }
    }
}

/// 側邊面板：白板的筆記卡片在主內容旁開啟完整編輯器（與主內容各自獨立）
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

/// 內容區：依目前位置顯示列表頁、編輯器或外掛面板，工具列一致
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
                // 容器本身成為一個元素（不覆蓋子元素的 identifier），E2E 用它確認編輯器已開啟
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

    /// 編輯器由各外掛向 PluginRegistry 註冊
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

/// 工具列：上一頁 / 下一頁、麵包屑、網格 / 列表、排序、在 Finder 中顯示、New Document
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
            // 分段控制有自己的底色，不放進工具列共用的玻璃底（否則邊緣露白）
            ToolbarItem(placement: Self.trailing) {
                IconSegmentedControl(selection: $layout, segments: [
                    .init(.grid, symbol: "square.grid.2x2", help: L("網格")),
                    .init(.list, symbol: "list.bullet", help: L("列表")),
                ])
            }
            .withoutSharedBackground()
        }
        if let path = route.filePath {
            // 編輯器：釘選、更多（在 Finder 中顯示、複製路徑、用其他 App 開啟…）
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

    /// macOS 的 `.primaryAction` 在前緣；設計稿的這組按鈕在尾端
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

    /// 資料夾 → 該資料夾；其他列表頁 → Vault 根目錄（檔案的「在 Finder 中顯示」在更多選單）
    private var revealURL: URL? {
        switch route {
        case .file: nil
        case .folder(let path): store.fs.url(for: path)
        case .panel: nil
        default: store.fs.root
        }
    }
}

/// 設計稿的 New Document 選單：新增檔案（`addNewFile`）、匯入（`addImport`）、新資料夾
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

/// New Document 選單的項目；工具列選單與 App 的「檔案」選單共用（Commands 拿不到 environment，所以明確傳入）
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
    /// macOS / iOS 26 起同一位置的項目共用一個玻璃底；麵包屑是文字，不要底
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
/// 把後面的項目推到工具列尾端（macOS 26 起 `.automatic` 會緊接在前緣項目之後）
private struct FlexibleToolbarSpace: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        }
    }
}
#endif
