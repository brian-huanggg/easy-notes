import EasyNotesUI
import SwiftUI
import UniformTypeIdentifiers

/// 從 Anki 匯入：選 `.apkg` → 分析（不寫入）→ 摘要 → 匯入（見 architecture/flashcards.md「Anki 匯入」）
struct AnkiImportSheet: View {
    private enum Stage {
        case choose
        case analyzing
        case ready(AnkiPackage, AnkiImportPlan)
        case importing
        case done(AnkiImportPlan)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var stage = Stage.choose
    @State private var picking = false
    private var store: ReviewStore { .shared }

    private static let types: [UTType] = [UTType(filenameExtension: "apkg"), UTType(filenameExtension: "colpkg")].compactMap { $0 } // l10n:fixed

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("從 Anki 匯入")).textStyle(.pageTitle).foregroundStyle(Palette.textPrimary)
                Spacer()
            }
            .padding(24)
            Divider()
            content
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360)
        .background(Palette.bgCanvas)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
            switch result {
            case let .success(url): analyze(url)
            case let .failure(error): stage = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .choose:
            VStack(alignment: .leading, spacing: 10) {
                Text(L("選擇 Anki 匯出的檔案（.apkg）。在 Anki 的「匯出」選「Anki 牌組套件」並勾選「包含媒體」。"))
                    .foregroundStyle(Palette.textSecondary)
                Text(L("牌組會對應成資料夾，卡片寫成筆記，複習紀錄一併帶過來。選擇檔案後會先顯示摘要，確認後才寫入。"))
                    .foregroundStyle(Palette.textSecondary)
            }
        case .analyzing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L("分析中…")) }
        case let .ready(_, plan):
            summary(plan, done: false)
        case .importing:
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L("匯入中…")) }
        case let .done(plan):
            summary(plan, done: true)
        case let .failed(message):
            Text(L("無法匯入：\(message)")).foregroundStyle(Palette.textSecondary)
        }
    }

    private func summary(_ plan: AnkiImportPlan, done: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(done ? L("匯入完成") : L("將會匯入"))
                    .textStyle(.sectionTitle).foregroundStyle(Palette.textPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("\(plan.notesAdded) 筆新的卡片筆記（\(plan.cards) 張卡片），寫入 \(plan.files.count) 個筆記檔、\(plan.decks.count) 個資料夾"))
                    if plan.notesExisting > 0 { Text(L("\(plan.notesExisting) 筆已經匯入過，不重複寫入")) }
                    Text(L("\(plan.entries.count) 筆複習紀錄、\(plan.media.count) 個圖片 / 媒體檔"))
                    if let hour = plan.rolloverHour {
                        Text(L("Anki 的換日時間是 \(hour) 點；到「牌組選項」把「新的一天開始時間」設成相同，每天出卡的時間才會一致。"))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                if !plan.missingMedia.isEmpty {
                    Text(L("套件中找不到 \(plan.missingMedia.count) 個媒體檔：\(plan.missingMedia.prefix(3).joined(separator: ", "))"))
                        .foregroundStyle(Palette.textSecondary)
                }
                if !plan.skipped.isEmpty {
                    Text(L("略過 \(plan.skipped.count) 筆（可以手動改寫成卡片語法）"))
                        .textStyle(.sectionTitle).foregroundStyle(Palette.textPrimary).padding(.top, 6)
                    ForEach(plan.skipped.prefix(20)) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.preview).lineLimit(1)
                            Text("\(item.deck) · \(reason(item.reason))").font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    if plan.skipped.count > 20 { Text(L("…還有 \(plan.skipped.count - 20) 筆")).foregroundStyle(Palette.textSecondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reason(_ reason: AnkiImportPlan.Reason) -> String {
        switch reason {
        case let .unsupportedType(name): L("不支援的筆記類型「\(name)」")
        case .imageOcclusion: L("圖片遮蓋（Image Occlusion）")
        case .clozeSpansLines: L("克漏字的答案跨行")
        case .unparsable: L("轉換後的語法與 Anki 的卡片不符")
        case .empty: L("沒有內容")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch stage {
            case .choose, .failed:
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("選擇檔案…")) { picking = true }.keyboardShortcut(.defaultAction)
            case .analyzing, .importing:
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(true)
            case let .ready(package, plan):
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("匯入")) { commit(plan, package) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.files.isEmpty && plan.entries.isEmpty)
            case .done:
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func analyze(_ url: URL) {
        stage = .analyzing
        Task {
            do {
                let (package, plan) = try await store.analyzeAnki(url)
                stage = .ready(package, plan)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func commit(_ plan: AnkiImportPlan, _ package: AnkiPackage) {
        stage = .importing
        Task {
            do {
                try await store.commitAnki(plan, package: package)
                stage = .done(plan)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
