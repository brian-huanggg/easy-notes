import EasyNotesUI
import SwiftUI

/// 卡片瀏覽（Anki 的 Browse）：牌組內的所有卡片、狀態篩選、搜尋；暫停 / 恢復 / 重設寫成紀錄事件
struct CardBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query: CardQuery
    @State private var confirmReset: StudyCard?

    private var store: ReviewStore { .shared }

    /// - Parameter deck: 資料夾路徑；nil = 所有牌組，"" = 未分類
    init(deck: String?) {
        _query = State(initialValue: CardQuery(deck: deck))
    }

    var body: some View {
        let cards = query.run(store.planner)
        VStack(spacing: 0) {
            header(count: cards.count)
            Divider()
            filters
            Divider()
            if cards.isEmpty {
                EmptyState(L("沒有符合的卡片"), message: L("換個篩選條件或搜尋文字試試。"), symbol: "rectangle.stack") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(cards) { card in
                    CardBrowserRow(card: card)
                        .contentShape(Rectangle())
                        .contextMenu { actions(card) }
                        .listRowBackground(Palette.bgPanel.color)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 680)
        #endif
        .background(Palette.bgPanel)
        .confirmationDialog(L("重設這張卡片？"), isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } })) {
            Button(L("重設"), role: .destructive) {
                if let card = confirmReset { store.apply(.reset, to: [card]) }
                confirmReset = nil
            }
        } message: {
            Text(L("卡片會回到新卡；之前的複習紀錄仍保留在紀錄檔中。"))
        }
    }

    // MARK: 標頭與篩選

    private func header(count: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L("瀏覽卡片"), systemImage: "list.bullet.rectangle")
                    .labelStyle(CompactLabelStyle(spacing: 8))
                    .textStyle(TextStyle(17, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(L("\(deckName) · \(count) 張卡片")).textStyle(TextStyle(12.5)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            IconButton("xmark", help: L("關閉")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }

    private var deckName: String {
        guard let deck = query.deck else { return L("所有牌組") }
        return deck.isEmpty ? L("未分類") : deck.replacingOccurrences(of: "/", with: " / ")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.textTertiary)
                    TextField(L("搜尋正反面文字或 #標籤"), text: $query.search)
                        .textFieldStyle(.plain)
                        .textStyle(TextStyle(13))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border.color))
                deckMenu
                orderMenu
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CardQuery.State.allCases, id: \.self) { state in
                        FilterChip(title(of: state), isSelected: query.state == state) { query.state = state }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var deckMenu: some View {
        Menu {
            Button(L("所有牌組")) { query.deck = nil }
            Divider()
            ForEach(store.decks.flatMapTree()) { deck in
                Button(String(repeating: "    ", count: deck.depth) + deck.name) { query.deck = deck.path }
            }
        } label: {
            Label(deckName, systemImage: "rectangle.stack").textStyle(.control)
        }
        .fixedSize()
    }

    private var orderMenu: some View {
        Picker(L("排序"), selection: $query.order) {
            Text(L("依筆記順序")).tag(CardQuery.Order.note)
            Text(L("依到期日")).tag(CardQuery.Order.due)
            Text(L("依遺忘次數")).tag(CardQuery.Order.lapses)
        }
        .labelsHidden()
        .fixedSize()
    }

    private func title(of state: CardQuery.State) -> String {
        switch state {
        case .all: L("全部")
        case .new: L("新卡")
        case .learning: L("學習中")
        case .review: L("複習")
        case .due: L("今天到期")
        case .suspended: L("已暫停")
        case .leech: "Leech"
        }
    }

    // MARK: 動作

    @ViewBuilder
    private func actions(_ card: StudyCard) -> some View {
        let schedule = store.schedule(of: card)
        Button(L("開啟筆記"), systemImage: "doc.text") {
            store.open(card)
            dismiss()
        }
        Divider()
        if schedule.suspended {
            Button(L("恢復"), systemImage: "play.circle") { store.apply(.unsuspend, to: [card]) }
        } else {
            Button(L("暫停"), systemImage: "pause.circle") { store.apply(.suspend, to: [card]) }
        }
        Button(L("重設為新卡…"), systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = card }
            .disabled(schedule.phase == .new)
    }
}

/// 一列：正面、背面、來源、狀態、到期、遺忘次數
private struct CardBrowserRow: View {
    let card: StudyCard
    private var store: ReviewStore { .shared }

    var body: some View {
        let schedule = store.schedule(of: card)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                CardText.text(card.front, size: 13.5, highlight: Palette.cardNew)
                    .textStyle(TextStyle(13.5, .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                CardText.text(card.back, size: 12.5, highlight: Palette.cardDue)
                    .textStyle(TextStyle(12.5))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                Text(source).textStyle(.meta).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                status(schedule)
                if let due = dueText(schedule) {
                    Text(due).textStyle(.meta).foregroundStyle(Palette.textTertiary)
                }
                if schedule.lapses > 0 {
                    Text(L("遺忘 \(schedule.lapses) 次")).textStyle(.meta).foregroundStyle(Palette.cardLearn)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(schedule.suspended ? 0.55 : 1)
    }

    private var source: String {
        let name = ((card.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let tags = store.tags(of: card).map { "#" + $0 }.joined(separator: " ")
        let location = L("\(name) · 第 \(card.line + 1) 行")
        return tags.isEmpty ? location : location + " · " + tags
    }

    private func status(_ schedule: CardSchedule) -> some View {
        let (title, color): (String, ColorToken) = if schedule.suspended {
            (L("已暫停"), Palette.textTertiary)
        } else {
            switch schedule.phase {
            case .new: (L("新卡"), Palette.cardNew)
            case .learning, .relearning: (L("學習中"), Palette.cardLearn)
            case .review: (L("複習"), Palette.cardDue)
            }
        }
        return Pill(title, dot: color)
    }

    private func dueText(_ schedule: CardSchedule) -> String? {
        guard schedule.phase != .new, let due = schedule.due else { return nil }
        return L("到期 \(due.formatted(date: .abbreviated, time: schedule.phase == .review ? .omitted : .shortened))")
    }
}
