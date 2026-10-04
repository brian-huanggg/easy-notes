import EasyNotesUI
import SwiftUI

/// 側邊欄「複習」的內容：牌組列表（設計稿 `rHTaT`），開始複習後換成複習畫面（`b2AjRQ`）
struct ReviewPanel: View {
    @Bindable private var store = ReviewStore.shared

    var body: some View {
        Group {
            if store.session != nil {
                ReviewSessionView()
            } else {
                DeckListView()
            }
        }
        .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button(L("好")) { store.notice = nil }
        }
    }
}

/// 牌組列表的篩選
private enum DeckFilter: Hashable {
    /// 只列出今天有卡片的牌組
    case due
    case all
}

struct DeckListView: View {
    @Bindable private var store = ReviewStore.shared
    @State private var filter = DeckFilter.all
    /// 牌組選項 sheet 的對象；"" = 根目錄（全域設定按鈕）
    @State private var optionsDeck: String?
    /// 自訂複習 sheet 的對象
    @State private var customStudy: DeckScopeRef?
    /// 匯出給 Anki 的資料夾與預設名稱
    @State private var export: (folder: AnkiExportFolder, name: String)?
    /// 卡片瀏覽 sheet 的對象（nil 牌組 = 所有牌組）
    @State private var browsing: DeckScopeRef?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// iPhone 直向：橫幅改上下排、牌組列改兩行，避免固定寬度的數字欄把內容撐出螢幕
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if store.loaded, store.cards.isEmpty {
                    EmptyState(L("還沒有卡片"), message: L("在筆記中寫「問題 :: 答案」、「中文 ;; English」或「{{克漏字}}」，就會出現在這裡。"), symbol: "rectangle.stack") {}
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    TodayBanner(compact: compact, start: { store.start(.all, title: L("所有牌組")) })
                    deckSection
                }
            }
            .padding(.vertical, Metrics.contentPadding)
            .padding(.horizontal, compact ? 20 : Metrics.contentPadding)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bgCanvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("牌組選項"), systemImage: "gearshape") { optionsDeck = "" }
                    .help(L("預設 preset 與全域設定"))
            }
        }
        .sheet(item: Binding(get: { optionsDeck.map(DeckRef.init) }, set: { optionsDeck = $0?.path })) { ref in
            DeckOptionsSheet(deck: ref.path)
        }
        .sheet(item: $customStudy) { ref in
            CustomStudySheet(deck: ref.deck)
        }
        .sheet(item: $browsing) { ref in
            CardBrowserSheet(deck: ref.deck)
        }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: export?.folder, contentType: .folder, defaultFilename: export?.name) { result in
            if case .failure(let error) = result { store.notice = L("無法匯出：\(error.localizedDescription)") }
            export = nil
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) {
                titleBlock
                Spacer(minLength: 16)
                chips
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                HStack(spacing: 6) { chips; actions }
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                chips
                actions
            }
        }
    }

    /// 所有牌組的瀏覽、自訂複習、匯出；單一牌組用牌組列的右鍵選單
    private var actions: some View {
        HStack(spacing: 6) {
            FilterChip(L("瀏覽卡片"), symbol: "list.bullet.rectangle", isSelected: false) { browsing = DeckScopeRef(deck: nil) }
                .help(L("檢視、搜尋所有卡片，暫停或重設"))
            FilterChip(L("自訂複習"), symbol: "slider.horizontal.below.rectangle", isSelected: false) { customStudy = DeckScopeRef(deck: nil) }
                .help(L("複習忘記的卡片或提前複習"))
            FilterChip(L("匯出給 Anki"), symbol: "square.and.arrow.up", isSelected: false) { exportToAnki(nil) }
                .help(L("所有卡片匯出成 Anki 可以匯入的文字檔"))
        }
        .disabled(store.cards.isEmpty)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("複習")).textStyle(.pageTitle).foregroundStyle(Palette.textPrimary)
            Text(subtitle).textStyle(.pageSubtitle).foregroundStyle(Palette.textSecondary)
        }
    }

    private var subtitle: String {
        let notes = Set(store.cards.map(\.noteID)).count
        var decks = 0
        func visit(_ deck: Deck) {
            decks += 1
            deck.children.forEach(visit)
        }
        store.decks.forEach(visit)
        return L("\(store.cards.count) 張卡片 · \(notes) 篇筆記 · \(decks) 個牌組")
    }

    private var chips: some View {
        HStack(spacing: 6) {
            FilterChip(L("今天到期"), isSelected: filter == .due) { filter = .due }
            FilterChip(L("所有牌組"), isSelected: filter == .all) { filter = .all }
            TagFilterMenu()
        }
    }

    private var deckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(L("牌組"), symbol: "rectangle.stack", detail: "\(visibleRows.count)")
                // compact 的牌組列在數字旁直接寫出名稱，不需要圖例
                if !compact { Legend() }
            }
            VStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.element.id) { offset, deck in
                    DeckRow(deck: deck, compact: compact, options: { optionsDeck = deck.path })
                        .contextMenu {
                            Button(L("瀏覽卡片…"), systemImage: "list.bullet.rectangle") {
                                browsing = DeckScopeRef(deck: deck.path)
                            }
                            Button(L("自訂複習…"), systemImage: "slider.horizontal.below.rectangle") {
                                customStudy = DeckScopeRef(deck: deck.path)
                            }
                            Button(L("牌組選項…"), systemImage: "slider.horizontal.3") { optionsDeck = deck.path }
                            Divider()
                            Button(L("匯出給 Anki…"), systemImage: "square.and.arrow.up") { exportToAnki(deck.path) }
                        }
                    if offset < visibleRows.count - 1 { Divider().overlay(Palette.border.color) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous).fill(Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous).strokeBorder(Palette.border.color))
        }
    }

    /// 牌組（nil = 全部）的卡片匯出成資料夾，每種筆記類型一個檔
    private func exportToAnki(_ deck: String?) {
        let files = store.ankiExport(deck: deck)
        guard !files.isEmpty else {
            store.notice = L("這個牌組還沒有可以匯出的卡片")
            return
        }
        let name = deck.map { $0.isEmpty ? L("未分類") : ($0 as NSString).lastPathComponent } ?? L("所有牌組")
        export = (AnkiExportFolder(files: files), L("\(name) Anki 匯出"))
    }

    /// 展開狀態與篩選後要顯示的列（樹狀攤平）
    private var visibleRows: [Deck] {
        var rows: [Deck] = []
        func visit(_ deck: Deck) {
            if filter == .due, store.counts(deck.scope).total == 0 { return }
            rows.append(deck)
            guard !store.collapsed.contains(deck.path) else { return }
            deck.children.forEach(visit)
        }
        store.decks.forEach(visit)
        return rows
    }
}

private struct DeckRef: Identifiable {
    let path: String
    var id: String { path }
}

private struct DeckScopeRef: Identifiable {
    /// nil = 所有牌組
    let deck: String?
    var id: String { deck.map { "deck:" + $0 } ?? "all" }
}

/// 標籤篩選學習：選一個標籤就開始複習
private struct TagFilterMenu: View {
    private var store: ReviewStore { .shared }

    var body: some View {
        Menu {
            let tags = store.planner.availableTags
            if tags.isEmpty {
                Text(L("筆記還沒有標籤"))
            }
            ForEach(tags, id: \.self) { tag in
                Button("#\(tag)") { store.start(.tag(tag), title: "#\(tag)") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "tag").font(.system(size: 11))
                Text(L("依標籤複習")).textStyle(.control)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .background(Capsule().fill(Palette.surfaceRaised))
            .overlay(Capsule().strokeBorder(Palette.border.color))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 今日橫幅：進度環、剩餘張數、開始複習
private struct TodayBanner: View {
    let compact: Bool
    let start: () -> Void
    private var store: ReviewStore { .shared }

    var body: some View {
        let left = store.counts(.all).total
        let done = store.planner.introducedToday.count + store.planner.reviewsToday.values.reduce(0, +)
        let total = done + left
        let progress = total == 0 ? 1 : Double(done) / Double(total)
        let waiting = store.decks.filter { store.counts($0.scope).total > 0 }.count
        let ring = ZStack {
            Circle().stroke(Palette.bgHover, lineWidth: 8)
            Circle().trim(from: 0, to: progress)
                .stroke(Palette.cardDue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((progress * 100).rounded()))%")
                .textStyle(TextStyle(17, .bold))
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(width: compact ? 64 : 76, height: compact ? 64 : 76)
        let summary = VStack(alignment: .leading, spacing: 6) {
            Text(left == 0 ? L("今天的卡片都複習完了") : L("今天還有 \(left) 張"))
                .textStyle(TextStyle(19, .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(L("已複習 \(done) / \(total) · \(waiting) 個牌組等待中"))
                .textStyle(.pageSubtitle)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let button = Button(action: start) {
            Label(L("開始複習"), systemImage: "play.fill")
                .frame(maxWidth: compact ? .infinity : nil)
        }
        .buttonStyle(PrimaryButtonStyle(size: .large))
        .disabled(left == 0)
        .keyboardShortcut(.return, modifiers: [])
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) { ring; summary }
                    button
                }
            } else {
                HStack(spacing: 22) {
                    ring
                    summary
                    Spacer(minLength: 12)
                    button
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, compact ? 18 : 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous).fill(Palette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous).strokeBorder(Palette.border.color))
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            item(L("新卡"), Palette.cardNew)
            item(L("學習中"), Palette.cardLearn)
            item(L("到期"), Palette.cardDue)
        }
    }

    private func item(_ title: String, _ color: ColorToken) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).textStyle(.meta).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// 設計稿 `C/Deck Row`：縮排、展開箭頭、圖示、名稱與說明、三個數字、選項、Study
private struct DeckRow: View {
    let deck: Deck
    let compact: Bool
    let options: () -> Void
    @Bindable private var store = ReviewStore.shared

    var body: some View {
        let counts = store.counts(deck.scope)
        Group {
            if compact {
                // iPhone 直向：第一行名稱 + 選項，第二行數字 + 複習（對齊名稱）
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        leading
                        Spacer(minLength: 8)
                        IconButton("slider.horizontal.3", help: L("牌組選項"), tint: Palette.textTertiary, action: options)
                    }
                    HStack(spacing: 12) {
                        inlineCount(counts.new, L("新卡"), Palette.cardNew)
                        inlineCount(counts.learning, L("學習中"), Palette.cardLearn)
                        inlineCount(counts.review, L("到期"), Palette.cardDue)
                        Spacer(minLength: 8)
                        studyButton(counts)
                    }
                    .padding(.leading, indent + 18 + 10)
                }
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 14) {
                    leading
                    Spacer(minLength: 12)
                    count(counts.new, L("新卡"), Palette.cardNew)
                    count(counts.learning, L("學習中"), Palette.cardLearn)
                    count(counts.review, L("到期"), Palette.cardDue)
                    IconButton("slider.horizontal.3", help: L("牌組選項"), tint: Palette.textTertiary, action: options)
                    studyButton(counts)
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var indent: CGFloat { CGFloat(deck.depth) * (compact ? 14 : 22) }

    /// 縮排、展開箭頭、圖示、名稱與說明
    private var leading: some View {
        HStack(spacing: compact ? 10 : 14) {
            HStack(spacing: 0) {
                Color.clear.frame(width: indent, height: 1)
                disclosure
            }
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.name)
                    .textStyle(TextStyle(13.5, deck.depth == 0 ? .semibold : .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(meta).textStyle(.meta).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            .layoutPriority(1)
        }
    }

    private func studyButton(_ counts: StudyPlanner.Counts) -> some View {
        Button {
            store.start(deck.scope, title: deck.path.isEmpty ? deck.name : deck.path.replacingOccurrences(of: "/", with: " / "))
        } label: {
            Label(L("複習"), systemImage: "play.fill")
                .labelStyle(CompactLabelStyle(spacing: 5))
                .textStyle(TextStyle(12, .semibold))
                .foregroundStyle(counts.total == 0 ? Palette.textTertiary : Palette.accent)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                    .fill(counts.total == 0 ? Palette.bgHover : Palette.accentSoft))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(counts.total == 0)
    }

    @ViewBuilder
    private var disclosure: some View {
        let collapsed = store.collapsed.contains(deck.path)
        Button {
            if collapsed { store.collapsed.remove(deck.path) } else { store.collapsed.insert(deck.path) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(deck.children.isEmpty ? 0 : 1)
        .disabled(deck.children.isEmpty)
        .accessibilityLabel(collapsed ? L("展開") : L("收合"))
    }

    private var icon: some View {
        let unfiled = deck.path.isEmpty
        return Image(systemName: unfiled ? "tray" : deck.children.isEmpty ? "rectangle.stack" : "folder")
            .font(.system(size: 13))
            .foregroundStyle(unfiled ? Palette.textSecondary : Palette.cardNew)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                .fill(unfiled ? Palette.bgHover : Palette.cardNewSoft))
    }

    private var meta: String {
        var parts = [L("\(deck.cardCount) 張卡片"), L("\(deck.noteCount) 篇筆記")]
        if deck.path.isEmpty { parts.insert(L("Vault 根目錄的筆記"), at: 0) }
        if let id = store.config.decks[deck.path], let preset = store.config.presets[id] {
            parts.append(L("Preset：\(preset.name)"))
        }
        return parts.joined(separator: " · ")
    }

    private func count(_ value: Int, _ label: String, _ color: ColorToken) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .textStyle(TextStyle(15, .semibold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? Palette.textTertiary : color)
            Text(label).textStyle(TextStyle(10, .medium)).foregroundStyle(Palette.textTertiary)
        }
        .frame(width: 46)
    }

    /// compact 用：「● 3 新卡」橫排，不佔固定欄寬
    private func inlineCount(_ value: Int, _ label: String, _ color: ColorToken) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value)")
                .textStyle(TextStyle(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? Palette.textTertiary : color)
            Text(label).textStyle(TextStyle(11, .medium)).foregroundStyle(Palette.textTertiary)
        }
        .fixedSize()
    }
}
