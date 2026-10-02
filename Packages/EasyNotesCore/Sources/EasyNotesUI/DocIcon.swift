import SwiftUI

/// 文件 icon（frontmatter `icon`）：Emoji 或 SF Symbol。
/// 檔案裡存成字串：Emoji 原樣（`icon: 🗺`），SF Symbol 加前綴（`icon: sf:map`）；Core 只存不解讀。
public enum DocIcon: Hashable, Sendable {
    case emoji(String)
    case symbol(String)

    static let symbolPrefix = "sf:"

    /// 空字串 → nil；`sf:` 但系統沒有這個 symbol（例如外部工具寫錯名稱）→ nil，由呼叫端顯示類型的預設圖示
    @MainActor
    public init?(_ raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix(Self.symbolPrefix) {
            let name = String(raw.dropFirst(Self.symbolPrefix.count))
            guard Self.symbolExists(name) else { return nil }
            self = .symbol(name)
        } else {
            self = .emoji(raw)
        }
    }

    /// 寫回 frontmatter 的字串
    public var frontmatterValue: String {
        switch self {
        case .emoji(let emoji): emoji
        case .symbol(let name): Self.symbolPrefix + name
        }
    }

    public var symbolName: String? {
        if case .symbol(let name) = self { name } else { nil }
    }

    public var emoji: String? {
        if case .emoji(let emoji) = self { emoji } else { nil }
    }

    @MainActor
    public static func symbolExists(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        #if os(iOS)
        return UIImage(systemName: name) != nil
        #else
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }
}

/// 圖示選單的內建清單。Apple 沒有列出所有 SF Symbols 的公開 API，所以內建常用的一組；
/// 搜尋框也接受直接輸入完整名稱。
public enum DocIconCatalog {
    public struct Group: Identifiable, Sendable {
        public var id: String { title }
        public let title: String
        public let symbols: [String]
    }

    public static let symbolGroups: [Group] = [
        Group(title: "文件", symbols: [
            "doc.text", "doc.richtext", "note.text", "book", "book.closed", "books.vertical", "text.book.closed",
            "bookmark", "newspaper", "magazine", "list.bullet.clipboard", "checklist", "list.bullet",
            "square.and.pencil", "pencil", "highlighter", "pencil.and.ruler", "paperclip", "folder", "archivebox",
            "tray", "doc.on.clipboard", "calendar", "calendar.badge.clock", "clock", "hourglass", "tag",
        ]),
        Group(title: "工作", symbols: [
            "briefcase", "building.2", "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis", "chart.bar.doc.horizontal",
            "target", "flag", "flag.checkered", "lightbulb", "bolt", "gearshape", "wrench.and.screwdriver", "hammer",
            "terminal", "chevron.left.forwardslash.chevron.right", "cpu", "server.rack", "network", "link", "key",
            "lock", "shield", "dollarsign.circle", "creditcard", "banknote", "trophy", "rosette",
        ]),
        Group(title: "學習", symbols: [
            "graduationcap", "brain", "brain.head.profile", "atom", "function", "sum", "percent", "x.squareroot",
            "testtube.2", "flask", "globe", "globe.asia.australia", "map", "mappin.and.ellipse", "safari",
            "puzzlepiece", "questionmark.circle", "exclamationmark.triangle", "info.circle", "magnifyingglass",
            "eye", "infinity", "wand.and.stars", "applepencil", "scribble.variable", "ruler",
        ]),
        Group(title: "生活", symbols: [
            "house", "heart", "star", "sparkles", "sun.max", "moon", "cloud", "leaf", "tree", "flame", "drop",
            "mountain.2", "beach.umbrella", "tent", "cup.and.saucer", "fork.knife", "cart", "bag", "gift",
            "airplane", "car", "tram", "sailboat", "bicycle", "figure.walk", "figure.run", "dumbbell", "bed.double",
            "pawprint", "stethoscope", "cross.case", "pills", "ticket", "crown", "medal", "face.smiling",
            "hand.thumbsup",
        ]),
        Group(title: "媒體與聯絡", symbols: [
            "camera", "photo", "music.note", "headphones", "mic", "film", "video", "tv", "gamecontroller",
            "paintpalette", "paintbrush", "theatermasks", "laptopcomputer", "iphone", "person", "person.2",
            "bubble.left.and.bubble.right", "envelope", "phone", "timer", "stopwatch", "alarm",
        ]),
    ]

    public static let emojis: [String] = Array("📝📌💡📚🗺🎯🧭🧠🔬🧪📊📈🗂📁🏷✅🚀🌱🔥⭐️🎨🧩💬🛠🎓🍀☕️🌙📅⏰💰🏠✈️🎵📷❤️").map(String.init)
}

/// 文件 icon 選單：分段控制「圖示 | 表情符號」。`choose(nil)` = 移除圖示
public struct DocIconPicker: View {
    enum Tab: Hashable { case symbol, emoji }

    let current: DocIcon?
    let choose: (DocIcon?) -> Void
    @State private var tab: Tab = .symbol
    @State private var query = ""
    @State private var emojiText = ""
    @State private var selection: DocIcon?
    @Environment(\.dismiss) private var dismiss

    public init(current: DocIcon?, choose: @escaping (DocIcon?) -> Void) {
        self.current = current
        self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("類型", selection: $tab) {
                Text("圖示").tag(Tab.symbol)
                Text("表情符號").tag(Tab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .symbol: symbolTab
            case .emoji: emojiTab
            }

            HStack {
                if current != nil {
                    Button("移除圖示", role: .destructive) {
                        choose(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("完成") {
                    if let selection, selection != current { choose(selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 420)
        .onAppear {
            selection = current
            tab = current?.emoji != nil ? .emoji : .symbol
            emojiText = current?.emoji ?? ""
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    // MARK: 圖示

    private var symbolTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜尋圖示，或輸入 SF Symbol 名稱", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let groups = filteredGroups
                    if groups.isEmpty {
                        Text("找不到「\(query)」").textStyle(.meta).foregroundStyle(Palette.textTertiary)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).textStyle(.groupLabel).foregroundStyle(Palette.textTertiary)
                            grid(group.symbols) { name in
                                Image(systemName: name)
                                    .font(.system(size: 17))
                                    .foregroundStyle(Palette.textSecondary)
                            } select: { .symbol($0) }
                        }
                    }
                }
            }
        }
    }

    /// 依名稱過濾；輸入的是完整且存在的名稱、但不在清單裡時，另外列在最前面
    private var filteredGroups: [DocIconCatalog.Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = DocIconCatalog.symbolGroups.map { group in
            DocIconCatalog.Group(title: group.title, symbols: group.symbols.filter(DocIcon.symbolExists))
        }
        guard !q.isEmpty else { return all }
        var groups = all.map { DocIconCatalog.Group(title: $0.title, symbols: $0.symbols.filter { $0.contains(q) }) }
            .filter { !$0.symbols.isEmpty }
        if DocIcon.symbolExists(q), !groups.contains(where: { $0.symbols.contains(q) }) {
            groups.insert(DocIconCatalog.Group(title: "名稱相符", symbols: [q]), at: 0)
        }
        return groups
    }

    // MARK: 表情符號

    private var emojiTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("輸入一個表情符號", text: $emojiText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: emojiText) { _, value in
                        // 只保留最後一個字（emoji 可能由多個 Unicode 組成，以字元計）
                        if value.count > 1, let last = value.last { emojiText = String(last) }
                        if let ch = emojiText.first { selection = .emoji(String(ch)) }
                    }
                #if os(macOS)
                Button("表情符號…") { NSApp.orderFrontCharacterPalette(nil) }
                #endif
            }
            ScrollView {
                grid(DocIconCatalog.emojis) { emoji in
                    Text(emoji).font(.system(size: 22))
                } select: { .emoji($0) }
            }
        }
    }

    // MARK: 網格

    private func grid<Label: View>(_ items: [String], @ViewBuilder label: @escaping (String) -> Label,
                                   select: @escaping (String) -> DocIcon) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 4), count: 10), alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                let icon = select(item)
                Button {
                    selection = icon
                    if case .emoji(let emoji) = icon { emojiText = emoji }
                } label: {
                    label(item)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                            .fill(selection == icon ? Palette.accentSoft : ColorToken.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item)
            }
        }
    }
}
