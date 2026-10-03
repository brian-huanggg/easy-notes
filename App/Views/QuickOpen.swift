import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// ⌘K 快速開啟：取代側邊欄的 `.searchable`。空白時列出最近的文件，輸入後用 FTS5 搜尋（`#標籤` 查標籤）。
/// ↑↓ 移動、Return 開啟、Esc 關閉
struct QuickOpen: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    /// iPhone 的 Search 分頁：開啟後不關閉，交給呼叫端
    var open: ((String) -> Void)?

    var body: some View {
        @Bindable var store = store
        let hits = results
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Palette.textTertiary)
                TextField(L("搜尋內容，或 #標籤"), text: $store.searchText)
                    .textFieldStyle(.plain)
                    .textStyle(TextStyle(15))
                    .focused($focused)
                    .onSubmit { choose(hits) }
                    #if os(iOS)
                    .submitLabel(.go)
                    #endif
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Divider().overlay(Palette.border)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text(store.searchText.isEmpty ? L("最近") : hits.isEmpty ? L("沒有符合的文件") : L("\(hits.count) 筆結果"))
                            .textStyle(.groupLabel)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            Button { pick(hit.path) } label: {
                                HitRow(hit: hit, symbol: store.plugins.symbol(for: store.kindID(hit.path)),
                                       tint: store.plugins.tint(for: store.kindID(hit.path)).base)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                                        .fill(index == highlighted ? Palette.bgSelected : ColorToken.clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
        }
        .background(Palette.bgCanvas)
        #if os(macOS)
        .frame(width: 560, height: 420)
        #endif
        .onAppear {
            store.searchText = ""
            highlighted = 0
            focused = true
        }
        .onChange(of: store.searchText) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(hits.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    /// 空白時：最近修改的 20 份文件
    private var results: [SearchHit] {
        if store.searchText.isEmpty {
            return store.files.prefix(20).map { SearchHit(path: $0.path, title: $0.title, snippet: "") }
        }
        return store.searchResults
    }

    private func choose(_ hits: [SearchHit]) {
        guard hits.indices.contains(highlighted) else { return }
        pick(hits[highlighted].path)
    }

    private func pick(_ path: String) {
        if let open { open(path) } else {
            store.navigate(.file(path))
            dismiss()
        }
    }
}

/// 標題 + 片段 + 路徑；片段中命中的文字（\u{1}…\u{2}）以粗體與強調色顯示
struct HitRow: View {
    let hit: SearchHit
    var symbol: String?
    var tint: ColorToken?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint ?? Palette.textSecondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).textStyle(.cardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(Self.highlight(hit.snippet))
                        .textStyle(.meta)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                Text(hit.path).textStyle(.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func highlight(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var highlighted = false
        for part in snippet.replacingOccurrences(of: "\n", with: " ")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\u{1}" || $0 == "\u{2}" }) {
            var piece = AttributedString(part)
            if highlighted {
                piece.font = TextStyle.meta.font.bold()
                piece.foregroundColor = Palette.accent.color
            }
            result += piece
            highlighted.toggle()
        }
        return result
    }
}
