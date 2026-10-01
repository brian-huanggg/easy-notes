import EasyNotesCore
import EasyNotesUI
import SwiftUI

struct ContentView: View {
    @Environment(VaultStore.self) private var store
    @State private var showBacklinks = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let path = store.selection, !store.isFolder(path) {
            editor(for: path)
                .navigationTitle(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .inspector(isPresented: $showBacklinks) {
                    BacklinksView()
                        .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
                }
                .toolbar {
                    ToolbarItem {
                        Button {
                            showBacklinks.toggle()
                        } label: {
                            Label("反向連結 \(store.backlinks.count)", systemImage: "link")
                        }
                        .help("顯示連到這篇筆記的其他筆記")
                    }
                }
        } else {
            ContentUnavailableView("選擇或建立一篇筆記", systemImage: "note.text",
                                   description: Text("所有筆記都存在 \(store.fs.root.path(percentEncoded: false))"))
        }
    }

    /// 編輯器由各外掛向 PluginRegistry 註冊
    @ViewBuilder
    private func editor(for path: String) -> some View {
        if let editor = store.plugins.editor(for: store.fs.kinds.kind(for: path)?.id, path: path) {
            editor
        } else {
            ContentUnavailableView("不支援的檔案類型", systemImage: "doc.questionmark")
        }
    }
}

// MARK: - 側邊欄

struct SidebarView: View {
    @Environment(VaultStore.self) private var store
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            if store.searchText.isEmpty {
                Section("檔案") {
                    OutlineGroup(store.tree, children: \.children) { node in
                        row(node)
                    }
                }
                if !store.tags.isEmpty {
                    Section("標籤") {
                        ForEach(store.tags) { tag in
                            Button {
                                store.searchText = "#" + tag.tag
                            } label: {
                                HStack {
                                    Label(tag.tag, systemImage: "number")
                                    Spacer()
                                    Text("\(tag.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if store.searchResults.isEmpty {
                Text("沒有符合的筆記").foregroundStyle(.secondary)
            } else {
                Section("\(store.searchResults.count) 筆結果") {
                    ForEach(store.searchResults) { hit in
                        HitRow(hit: hit).tag(hit.path)
                    }
                }
            }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "搜尋內容，或 #標籤")
        .navigationTitle("EasyNotes")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(store.plugins.newFileCommands) { command in
                        Button(command.title, systemImage: command.symbol) {
                            store.create(command.kind, title: command.defaultName)
                        }
                    }
                    Button("新資料夾", systemImage: "folder.badge.plus") { store.createFolder() }
                } label: {
                    Label("新增", systemImage: "plus")
                }
            }
        }
        .refreshable { await store.syncIndex() }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("確定") {
                if let path = renaming {
                    Task { await store.rename(path, to: newName) }
                }
                renaming = nil
            }
        } message: {
            Text("其他筆記中指向它的 [[連結]] 會一併更新。")
        }
    }

    private func row(_ node: VaultNode) -> some View {
        Label(node.displayName, systemImage: icon(for: node))
            .tag(node.path)
            .contextMenu {
                Button("重新命名", systemImage: "pencil") {
                    newName = node.displayName
                    renaming = node.path
                }
                Button("移到垃圾桶", systemImage: "trash", role: .destructive) {
                    Task { await store.delete(node.path) }
                }
            }
    }

    private func icon(for node: VaultNode) -> String {
        if node.isFolder { return "folder" }
        return store.plugins.symbol(for: store.fs.kinds.kind(for: node.path)?.id)
    }
}

// MARK: - 反向連結

struct BacklinksView: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        List {
            Section {
                if store.backlinks.isEmpty {
                    Text("還沒有筆記連到這裡。在其他筆記輸入 [[ 即可建立連結。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.backlinks) { hit in
                        Button {
                            store.selection = hit.path
                        } label: {
                            HitRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("反向連結")
            }
        }
    }
}

/// 標題 + 片段；片段中命中的文字（\u{1}…\u{2}）以粗體與強調色顯示
struct HitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.title).font(.body.weight(.medium)).lineLimit(1)
            if !hit.snippet.isEmpty {
                Text(Self.highlight(hit.snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(hit.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    static func highlight(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var highlighted = false
        for part in snippet.replacingOccurrences(of: "\n", with: " ")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\u{1}" || $0 == "\u{2}" }) {
            var piece = AttributedString(part)
            if highlighted {
                piece.font = .caption.bold()
                piece.foregroundColor = .accentColor
            }
            result += piece
            highlighted.toggle()
        }
        return result
    }
}
