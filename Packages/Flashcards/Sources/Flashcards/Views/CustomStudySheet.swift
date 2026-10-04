import EasyNotesUI
import SwiftUI

/// 自訂複習：增加今天的上限、複習忘記的卡片、提前複習（見 architecture/flashcards.md「自訂複習」）
struct CustomStudySheet: View {
    enum Option: Hashable, CaseIterable {
        case extend, forgotten, reviewAhead
    }

    /// 資料夾路徑；nil = 所有牌組（工具列），"" = 未分類
    let deck: String?
    @Environment(\.dismiss) private var dismiss
    @State private var option: Option
    @State private var extraNew: Int
    @State private var extraReview: Int
    @State private var forgottenDays = 1
    @State private var aheadDays = 1

    private var store: ReviewStore { .shared }

    init(deck: String?) {
        self.deck = deck
        let store = ReviewStore.shared
        // 「所有牌組」沒有單一的上限可以加
        _option = State(initialValue: deck == nil ? .forgotten : .extend)
        _extraNew = State(initialValue: deck.map { store.extraLimit($0, new: true) } ?? 0)
        _extraReview = State(initialValue: deck.map { store.extraLimit($0, new: false) } ?? 0)
    }

    private var options: [Option] { deck == nil ? [.forgotten, .reviewAhead] : Option.allCases }

    private var deckName: String {
        guard let deck else { return L("所有牌組") }
        return deck.isEmpty ? L("未分類") : deck.replacingOccurrences(of: "/", with: " / ")
    }

    private var study: CustomStudy? {
        switch option {
        case .extend: nil
        case .forgotten: CustomStudy(.forgotten, days: forgottenDays, deck: deck)
        case .reviewAhead: CustomStudy(.reviewAhead, days: aheadDays, deck: deck)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                Picker(L("選項"), selection: $option) {
                    ForEach(options, id: \.self) { Text(title(of: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                fields
                Spacer(minLength: 0)
            }
            .padding(24)
            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 480, height: 340)
        #endif
        .background(Palette.bgPanel)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L("自訂複習"), systemImage: "slider.horizontal.below.rectangle")
                    .labelStyle(CompactLabelStyle(spacing: 8))
                    .textStyle(TextStyle(17, .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(deckName).textStyle(TextStyle(12.5)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            IconButton("xmark", help: L("關閉")) { dismiss() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }

    private func title(of option: Option) -> String {
        switch option {
        case .extend: L("增加上限")
        case .forgotten: L("忘記的卡")
        case .reviewAhead: L("提前複習")
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch option {
        case .extend:
            OptionSection(L("今天多加"), symbol: "plus.circle") {
                OptionRow(L("新卡"), hint: L("每日上限 \(preset.newPerDay) 張")) {
                    NumberField(value: $extraNew, range: 0...9999, unit: L("張"))
                }
                OptionRow(L("複習"), hint: L("每日上限 \(preset.reviewsPerDay) 張")) {
                    NumberField(value: $extraReview, range: 0...99999, unit: L("張"))
                }
                hint(L("只在今天有效，跟著設定檔同步到其他裝置；從母牌組開始複習時，母牌組的上限仍然適用。"))
            }
        case .forgotten:
            OptionSection(L("複習忘記的卡片"), symbol: "arrow.uturn.backward") {
                OptionRow(L("最近幾天"), hint: L("含今天，按過「重來」的卡片")) {
                    NumberField(value: $forgottenDays, range: 1...365, unit: L("天"))
                }
                selectionHint
            }
        case .reviewAhead:
            OptionSection(L("提前複習"), symbol: "forward") {
                OptionRow(L("幾天內到期"), hint: L("含已到期的複習卡")) {
                    NumberField(value: $aheadDays, range: 1...365, unit: L("天"))
                }
                selectionHint
            }
        }
    }

    private var preset: Preset { store.config.preset(for: deck ?? "") }

    @ViewBuilder
    private var selectionHint: some View {
        if let study {
            let count = store.customCount(study)
            hint(count == 0 ? L("沒有符合的卡片")
                 : L("會加入 \(count) 張卡片（最多 \(StudyPlanner.filteredLimit) 張）；不受每日上限限制，提前作答不算在今天的複習數內。"))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .textStyle(TextStyle(12))
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L("取消")) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(option == .extend ? L("儲存") : L("開始複習")) { confirm() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(study.map { store.customCount($0) == 0 } ?? false)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func confirm() {
        if let study {
            store.start(.filtered(study), title: "\(title(of: option)) · \(deckName)")
        } else if let deck {
            store.extendLimits(deck, new: extraNew, review: extraReview)
        }
        dismiss()
    }
}
