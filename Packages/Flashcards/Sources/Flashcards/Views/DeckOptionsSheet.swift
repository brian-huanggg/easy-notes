import EasyNotesUI
import SwiftUI

/// 牌組選項（設計稿 `AYlad`）：牌組使用的 preset、preset 的欄位、全域設定。
/// 在草稿上編輯，按「完成」才寫入這台裝置的設定檔（只寫有變動的欄位）。
struct DeckOptionsSheet: View {
    /// 資料夾路徑；"" = 根目錄（工具列的設定按鈕、未分類）
    let deck: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ReviewStore.shared.config
    @State private var renaming: String?
    @State private var newName = ""
    @State private var confirmDelete = false

    private var store: ReviewStore { .shared }
    private var presetID: String { draft.presetID(for: deck) }
    private var inherits: Bool { draft.decks[deck] == nil }
    private var title: String { deck.isEmpty ? L("預設與全域設定") : L("\((deck as NSString).lastPathComponent) 的牌組選項") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    presetBar
                    Divider()
                    fields.padding(24)
                    Divider()
                    globalSettings.padding(24)
                }
            }
            Divider()
            footer
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 900, minHeight: 520, idealHeight: 760)
        #endif
        .background(Palette.bgPanel)
        .alert(L("重新命名 preset"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("名稱"), text: $newName)
            Button(L("取消"), role: .cancel) { renaming = nil }
            Button(L("確定")) {
                if let id = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    draft.presets[id]?.name = newName.trimmingCharacters(in: .whitespaces)
                }
                renaming = nil
            }
        }
        .confirmationDialog(L("刪除「\(draft.presets[presetID]?.name ?? "")」？"), isPresented: $confirmDelete) {
            Button(L("刪除"), role: .destructive) { draft.removePreset(presetID) }
        } message: {
            Text(L("使用它的牌組會改回繼承上層。"))
        }
    }

    // MARK: 標頭

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: "slider.horizontal.3")
                    .labelStyle(CompactLabelStyle(spacing: 8))
                    .textStyle(TextStyle(17, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle).textStyle(TextStyle(12.5)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            IconButton("xmark", help: L("關閉")) { dismiss() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }

    private var subtitle: String {
        let children = descendants(of: deck)
        let scope = deck.isEmpty ? L("所有沒有指定 preset 的牌組") : children.isEmpty ? L("「\((deck as NSString).lastPathComponent)」")
            : L("「\((deck as NSString).lastPathComponent)」與 \(children.count) 個子牌組")
        return L("套用到\(scope) · 子資料夾沒有指定 preset 時繼承上層")
    }

    private func descendants(of path: String) -> [String] {
        var result: [String] = []
        func visit(_ deck: Deck) {
            if !path.isEmpty, deck.path.hasPrefix(path + "/") { result.append(deck.path) }
            deck.children.forEach(visit)
        }
        store.decks.forEach(visit)
        return result
    }

    // MARK: Preset

    private var presetBar: some View {
        HStack(spacing: 12) {
            Text("Preset").textStyle(.control).foregroundStyle(Palette.textSecondary)
            presetMenu
            Text(usage).textStyle(TextStyle(12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var usage: String {
        let count = store.decks.flatMapTree().filter { draft.presetID(for: $0.path) == presetID }.count
        return L("\(count) 個牌組使用 · 修改會影響所有使用這個 preset 的牌組")
    }

    private var presetMenu: some View {
        Menu {
            if !deck.isEmpty {
                Button {
                    draft.decks[deck] = nil
                } label: {
                    Label(L("繼承上層（\(draft.presets[draft.presetID(for: (deck as NSString).deletingLastPathComponent)]?.name ?? L("預設"))）"),
                          systemImage: inherits ? "checkmark" : "arrow.turn.left.up")
                }
                Divider()
            }
            ForEach(draft.sortedPresetIDs, id: \.self) { id in
                Button {
                    assign(id)
                } label: {
                    if !inherits || deck.isEmpty, id == presetID { Label(draft.presets[id]!.name, systemImage: "checkmark") }
                    else { Text(draft.presets[id]!.name) }
                }
            }
            Divider()
            Button(L("新增 preset…"), systemImage: "plus") {
                let id = SRSConfig.newPresetID()
                var preset = Preset()
                preset.name = L("新的 preset")
                draft.presets[id] = preset
                assign(id)
                newName = preset.name
                renaming = id
            }
            Button(L("複製「\(draft.presets[presetID]?.name ?? "")」"), systemImage: "plus.square.on.square") {
                let id = SRSConfig.newPresetID()
                var preset = draft.presets[presetID] ?? Preset()
                preset.name += L(" 副本")
                draft.presets[id] = preset
                assign(id)
            }
            Button(L("重新命名…"), systemImage: "pencil") {
                newName = draft.presets[presetID]?.name ?? ""
                renaming = presetID
            }
            Button(L("刪除「\(draft.presets[presetID]?.name ?? "")」…"), systemImage: "trash", role: .destructive) {
                confirmDelete = true
            }
            .disabled(presetID == SRSConfig.defaultPresetID)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Palette.cardNew).frame(width: 8, height: 8)
                Text(draft.presets[presetID]?.name ?? L("預設")).textStyle(TextStyle(13, .medium))
                if inherits, !deck.isEmpty { Text(L("（繼承）")).textStyle(.meta).foregroundStyle(Palette.textTertiary) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall).fill(Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall).strokeBorder(Palette.border.color))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 根目錄沒有上層可繼承：選 preset 就是指定根目錄
    private func assign(_ id: String) {
        if deck.isEmpty, id == SRSConfig.defaultPresetID { draft.decks[""] = nil } else { draft.decks[deck] = id }
    }

    private var preset: Binding<Preset> {
        let id = presetID
        return Binding(get: { draft.presets[id] ?? Preset() }, set: { draft.presets[id] = $0 })
    }

    // MARK: 欄位

    private var fields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 36) {
                leftColumn.frame(minWidth: 360)
                rightColumn.frame(minWidth: 360)
            }
            VStack(alignment: .leading, spacing: 24) {
                leftColumn
                rightColumn
            }
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            OptionSection(L("每日上限"), symbol: "calendar") {
                OptionRow(L("新卡"), hint: L("母牌組的上限涵蓋所有子牌組")) {
                    NumberField(value: preset.newPerDay, range: 0...9999, unit: L("張 / 天"))
                }
                OptionRow(L("複習"), hint: L("今天學的新卡也算在內")) {
                    NumberField(value: preset.reviewsPerDay, range: 0...99999, unit: L("張 / 天"))
                }
            }
            OptionSection(L("學習步驟"), symbol: "stairs") {
                OptionRow("Learning steps", hint: L("新卡在畢業前的間隔，例如 1m 10m")) {
                    StepsField(steps: preset.learningSteps)
                }
                OptionRow("Relearning steps", hint: L("遺忘後重新學習的間隔")) {
                    StepsField(steps: preset.relearningSteps)
                }
            }
            OptionSection("FSRS", symbol: "brain") {
                OptionRow(L("目標記憶率"), hint: L("越高複習越頻繁")) {
                    TextField("", value: preset.desiredRetention, format: .number.precision(.fractionLength(2)))
                        .optionField(width: 56)
                        .onSubmit { preset.wrappedValue.desiredRetention = min(0.99, max(0.7, preset.wrappedValue.desiredRetention)) }
                }
                OptionRow(L("最大間隔")) {
                    NumberField(value: preset.maximumInterval, range: 1...36_500, unit: L("天"))
                }
                OptionRow(L("參數"), hint: preset.wrappedValue.w == Preset().w ? L("FSRS-6 預設參數") : L("已最佳化的參數")) {
                    Button(L("最佳化…")) {}
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(true)
                        .help(L("參數最佳化在 3d 加入"))
                }
            }
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            OptionSection(L("順序"), symbol: "arrow.up.arrow.down") {
                OptionRow(L("新卡順序")) {
                    Picker("", selection: preset.newOrder) {
                        Text(L("依檔案內順序")).tag(Preset.NewOrder.file)
                        Text(L("隨機")).tag(Preset.NewOrder.random)
                    }
                    .labelsHidden().fixedSize()
                }
                OptionRow(L("複習排序")) {
                    Picker("", selection: preset.reviewOrder) {
                        Text(L("依到期日")).tag(Preset.ReviewOrder.due)
                        Text(L("依可回想率")).tag(Preset.ReviewOrder.retrievability)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            OptionSection(L("埋藏 sibling"), symbol: "eye.slash") {
                OptionRow(L("埋藏新卡 sibling"), hint: L("同一行產生的其他新卡延到明天")) {
                    Toggle("", isOn: preset.buryNew).labelsHidden().toggleStyle(.switch)
                }
                OptionRow(L("埋藏複習卡 sibling")) {
                    Toggle("", isOn: preset.buryReviews).labelsHidden().toggleStyle(.switch)
                }
            }
            OptionSection("Leech", symbol: "ant") {
                OptionRow(L("門檻"), hint: L("遺忘次數達到後處理")) {
                    NumberField(value: preset.leechThreshold, range: 1...99, unit: L("次"))
                }
                OptionRow(L("動作"), hint: L("標籤 leech 可用「依標籤複習」篩選")) {
                    Picker("", selection: preset.leechAction) {
                        Text(L("只加標籤")).tag(Preset.LeechAction.tag)
                        Text(L("暫停")).tag(Preset.LeechAction.suspend)
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var globalSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                Text(L("全域設定")).textStyle(.sectionTitle).foregroundStyle(Palette.textPrimary)
                Text(L("· 所有牌組共用")).textStyle(.sectionDetail).foregroundStyle(Palette.textTertiary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 32) { globalRows }
                VStack(alignment: .leading, spacing: 12) { globalRows }
            }
        }
    }

    @ViewBuilder
    private var globalRows: some View {
        HStack {
            Text(L("新的一天開始於")).textStyle(TextStyle(13))
            Picker("", selection: $draft.global.rolloverHour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        Toggle(L("按鈕顯示下次間隔"), isOn: $draft.global.showIntervals).toggleStyle(.switch).textStyle(TextStyle(13))
        Toggle(L("參數最佳化提醒"), isOn: $draft.global.optimizeReminder).toggleStyle(.switch).textStyle(TextStyle(13))
    }

    // MARK: 下方

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
            Text(L("存在 .easynotes/srs/，跟著 Vault 同步；兩台裝置改不同欄位都會保留"))
                .textStyle(TextStyle(12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
            Spacer()
            Button(L("還原預設")) {
                let name = preset.wrappedValue.name
                var reset = Preset()
                reset.name = name
                preset.wrappedValue = reset
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(L("把這個 preset 的欄位改回 Anki 的預設值"))
            Button(L("完成")) {
                store.save(draft)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

extension [Deck] {
    /// 樹狀攤平
    func flatMapTree() -> [Deck] {
        flatMap { [$0] + $0.children.flatMapTree() }
    }
}

// MARK: - 元件

struct OptionSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .labelStyle(CompactLabelStyle(spacing: 6))
                .textStyle(.sectionTitle)
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 14) { content }
        }
    }
}

struct OptionRow<Control: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let control: Control

    init(_ title: String, hint: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(TextStyle(13, .medium)).foregroundStyle(Palette.textPrimary)
                if let hint { Text(hint).textStyle(TextStyle(11.5)).foregroundStyle(Palette.textTertiary) }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                      format: .number.grouping(.never))
                .optionField(width: 58)
            if let unit { Text(unit).textStyle(TextStyle(12)).foregroundStyle(Palette.textTertiary) }
        }
    }
}

/// `1m 10m`、`30s 1h 1d`：秒、分、時、天
private struct StepsField: View {
    @Binding var steps: [TimeInterval]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("1m 10m", text: $text)
            .optionField(width: 96)
            .focused($focused)
            .onAppear { text = Self.format(steps) }
            .onChange(of: steps) { _, new in if !focused { text = Self.format(new) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let parsed = Self.parse(text) { steps = parsed }
        text = Self.format(steps)
    }

    static func parse(_ text: String) -> [TimeInterval]? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
        var result: [TimeInterval] = []
        for token in text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }) {
            let unit = token.last.flatMap { units[$0] }
            let number = unit == nil ? token : token.dropLast()
            guard let value = Double(number), value > 0 else { return nil }
            result.append(value * (unit ?? 60))
        }
        return result
    }

    static func format(_ steps: [TimeInterval]) -> String {
        steps.map { seconds in
            for (unit, size) in [("d", 86_400.0), ("h", 3600), ("m", 60)] where seconds >= size && seconds.truncatingRemainder(dividingBy: size) == 0 {
                return "\(Int(seconds / size))\(unit)"
            }
            return "\(Int(seconds))s"
        }
        .joined(separator: " ")
    }
}

extension View {
    func optionField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .textStyle(TextStyle(13))
            .monospacedDigit()
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border.color))
    }
}
