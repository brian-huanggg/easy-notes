import EasyNotesUI
import SwiftUI

/// 複習畫面（設計稿 `b2AjRQ`）：正面 → 顯示答案 → 四個評分鍵。
/// 鍵盤（Mac、iPad 外接鍵盤）：Space 顯示答案 / Good、1–4 評分、U 復原、E 編輯筆記、Esc 離開
struct ReviewSessionView: View {
    @Bindable private var store = ReviewStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressBar
            ScrollView {
                Group {
                    if let card = store.session?.current {
                        CardView(card: card, showingAnswer: store.session?.showingAnswer == true)
                    } else {
                        finished
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
            .frame(maxHeight: .infinity)
            if store.session?.current != nil { ratingBar }
        }
        .background(Palette.bgCanvas)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(action: handleKey)
    }

    // MARK: 上方

    private var topBar: some View {
        HStack {
            HStack(spacing: 10) {
                IconButton("xmark", help: L("離開（Esc）")) { store.end() }
                Label(store.session?.title ?? "", systemImage: "rectangle.stack")
                    .labelStyle(CompactLabelStyle(spacing: 6))
                    .textStyle(TextStyle(13, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let counts = store.sessionCounts
            HStack(spacing: 14) {
                QueueCount(value: counts.new, label: L("新卡"), color: Palette.cardNew)
                QueueCount(value: counts.learning, label: L("學習中"), color: Palette.cardLearn)
                QueueCount(value: counts.review, label: L("到期"), color: Palette.cardDue)
            }
            HStack(spacing: 8) {
                if store.session?.canUndo == true {
                    Button { store.undo() } label: { Label(L("復原"), systemImage: "arrow.uturn.backward") }
                        .buttonStyle(SecondaryButtonStyle())
                        .help(L("復原上一次作答（U）"))
                }
                if store.session?.current != nil {
                    Button { store.editCurrentNote() } label: { Label(L("編輯筆記"), systemImage: "square.and.pencil") }
                        .buttonStyle(SecondaryButtonStyle())
                        .help(L("開啟卡片所在的筆記（E）"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var progressBar: some View {
        let session = store.session
        let remaining = store.sessionCounts.total
        let done = session?.answered ?? 0
        let progress = done + remaining == 0 ? 1 : Double(done) / Double(done + remaining)
        return GeometryReader { proxy in
            Rectangle().fill(Palette.accent).frame(width: proxy.size.width * progress)
        }
        .frame(height: 3)
        .background(Palette.border)
    }

    private var finished: some View {
        EmptyState(L("這次的卡片都複習完了"), message: L("已作答 \(store.session?.answered ?? 0) 次。learning 中的卡片到期後會再出現。"),
                   symbol: "checkmark.circle") {
            Button(L("回到牌組")) { store.end() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 評分

    private var ratingBar: some View {
        VStack(spacing: 14) {
            if store.session?.showingAnswer == true {
                let previews = store.previews()
                HStack(spacing: 10) {
                    ForEach(Grade.allCases, id: \.self) { grade in
                        RatingButton(grade: grade, interval: store.config.global.showIntervals ? previews[grade].map { Self.interval($0.ivl) } : nil) {
                            store.answer(grade)
                        }
                    }
                }
            } else {
                Button { store.showAnswer() } label: {
                    Text(L("顯示答案")).frame(width: 300)
                }
                .buttonStyle(PrimaryButtonStyle(size: .large))
            }
            HStack(spacing: 16) {
                ForEach(["Space = \(store.session?.showingAnswer == true ? L("良好") : L("顯示答案"))", L("U 復原"), L("E 編輯筆記"), L("Esc 離開")], id: \.self) {
                    Text($0).textStyle(TextStyle(11)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }

    /// `ivl`：正數 = 天，負數 = 秒
    static func interval(_ ivl: Int) -> String {
        if ivl < 0 {
            let seconds = -ivl
            if seconds < 60 { return L("< 1 分鐘") }
            if seconds < 3600 { return L("\(seconds / 60) 分鐘") }
            if seconds < 86_400 { return L("\(format(Double(seconds) / 3600)) 小時") }
            return L("\(format(Double(seconds) / 86_400)) 天")
        }
        if ivl < 30 { return L("\(ivl) 天") }
        if ivl < 365 { return L("\(format(Double(ivl) / 30.4)) 個月") }
        return L("\(format(Double(ivl) / 365)) 年")
    }

    private static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        let showing = store.session?.showingAnswer == true
        switch press.key {
        case .space:
            if store.session?.current == nil { return .ignored }
            if showing { store.answer(.good) } else { store.showAnswer() }
            return .handled
        case .escape:
            store.end()
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "1", "2", "3", "4":
            guard showing, let value = Int(press.characters), let grade = Grade(rawValue: value) else { return .ignored }
            store.answer(grade)
        case "u": store.undo()
        case "e": store.editCurrentNote()
        default: return .ignored
        }
        return .handled
    }
}

private struct QueueCount: View {
    let value: Int
    let label: String
    let color: ColorToken

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value)").textStyle(TextStyle(13, .semibold)).monospacedDigit().foregroundStyle(Palette.textPrimary)
            Text(label).textStyle(.meta).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// 卡片：正面、答案、來源與標籤
struct CardView: View {
    let card: StudyCard
    let showingAnswer: Bool
    private var store: ReviewStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("問題")).textStyle(TextStyle(10, .semibold, tracking: 0.8)).foregroundStyle(Palette.textTertiary)
                CardText(segments: card.front, style: TextStyle(card.type == .cloze ? 26 : 34, .semibold),
                         highlight: Palette.cardNew)
                    .foregroundStyle(Palette.textPrimary)
            }
            if showingAnswer {
                Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 30)
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("答案")).textStyle(TextStyle(10, .semibold, tracking: 0.8)).foregroundStyle(Palette.textTertiary)
                    CardText(segments: card.back, style: TextStyle(23, .semibold), highlight: Palette.cardDue)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            footer.padding(.top, 26)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .padding(.horizontal, 54)
        .padding(.bottom, 32)
        .frame(maxWidth: 780)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border.color))
    }

    private var footer: some View {
        let tags = store.tags(of: card)
        let lapses = store.schedule(of: card).lapses
        return ViewThatFits(in: .horizontal) {
            HStack {
                source
                Spacer(minLength: 12)
                pills(tags, lapses)
            }
            VStack(alignment: .leading, spacing: 10) {
                source
                pills(tags, lapses)
            }
        }
    }

    private var source: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
            Text(((card.path as NSString).lastPathComponent as NSString).deletingPathExtension)
                .textStyle(TextStyle(12.5, .medium))
                .foregroundStyle(Palette.accent)
            Text(L("· 第 \(card.line + 1) 行")).textStyle(.meta).foregroundStyle(Palette.textTertiary)
        }
        .lineLimit(1)
    }

    private func pills(_ tags: [String], _ lapses: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { Pill("#\($0)") }
            if lapses > 0 { Pill(L("遺忘 \(lapses) 次"), dot: Palette.cardLearn) }
        }
    }
}

private struct RatingButton: View {
    let grade: Grade
    let interval: String?
    let action: () -> Void

    var body: some View {
        let style = Self.style(grade)
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 7) {
                    Text(style.title).textStyle(TextStyle(15, .semibold)).foregroundStyle(style.text)
                    Text("\(grade.rawValue)")
                        .textStyle(TextStyle(10.5, .semibold))
                        .foregroundStyle(grade == .good ? AnyShapeStyle(Color.white) : AnyShapeStyle(Palette.textSecondary))
                        .frame(width: 17, height: 17)
                        .background(RoundedRectangle(cornerRadius: 4).fill(grade == .good ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(Palette.surfaceRaised)))
                }
                if let interval {
                    Text(interval)
                        .textStyle(TextStyle(11.5, .medium))
                        .foregroundStyle(grade == .good ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(Palette.textTertiary))
                }
            }
            .frame(maxWidth: 176)
            .frame(maxWidth: .infinity)
            .padding(.top, 11)
            .padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous).fill(style.fill))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium, style: .continuous)
                .strokeBorder(grade == .good ? Color.clear : Palette.border.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 176)
        .accessibilityLabel(style.title + (interval.map { L("，\($0)") } ?? ""))
    }

    private static func style(_ grade: Grade) -> (title: String, fill: ColorToken, text: AnyShapeStyle) {
        switch grade {
        case .again: (L("重來"), Palette.cardLearnSoft, AnyShapeStyle(Palette.cardLearn))
        case .hard: (L("困難"), Palette.warnSoft, AnyShapeStyle(Palette.warnDeep))
        case .good: (L("良好"), Palette.cardDue, AnyShapeStyle(Color.white))
        case .easy: (L("簡單"), Palette.cardNewSoft, AnyShapeStyle(Palette.cardNew))
        }
    }
}
