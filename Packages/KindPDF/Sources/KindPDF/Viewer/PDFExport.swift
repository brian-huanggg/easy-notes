import EasyNotesUI
import Foundation
import Observation
import SwiftUI

/// 一次匯出：背景以 `PDFExporter` 壓平到暫存檔，完成後可分享或存進 Vault（見 architecture/pdf.md「匯出」）
@MainActor @Observable
final class PDFExportJob: Identifiable {
    enum State: Equatable {
        case running(done: Int, total: Int)
        case finished(URL)
        case failed
    }

    private(set) var state: State = .running(done: 0, total: 0)
    /// 存進 Vault 後的路徑
    private(set) var savedPath: String?
    @ObservationIgnored private let document: PDFInkDocument
    @ObservationIgnored private var task: Task<Bool, Never>?
    @ObservationIgnored private let folder = FileManager.default.temporaryDirectory
        .appending(path: "PDFExport-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(document: PDFInkDocument) {
        self.document = document
    }

    /// 分享時看到的檔名與 Vault 內的第一個候選相同：`<檔名>（標註）.pdf`
    private var fileName: String {
        (PDFExporter.exportedPath(forPDF: document.path, exists: { _ in false }) as NSString).lastPathComponent
    }

    func start() {
        guard task == nil else { return }
        document.flush() // 編輯中的便利貼文字先收進標註
        // PDFInk（`[String: Any]`）不是 Sendable：以旁檔格式傳進背景
        guard let inkData = try? document.ink.data() else { state = .failed; return }
        let source = document.pdfURL, folder = folder
        let destination = folder.appending(path: fileName)
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.report(done: done, total: total) }
        }
        // detached 不是子工作：取消要直接取消它，進度回呼才看得到 `Task.isCancelled`
        let work = Task.detached(priority: .userInitiated) {
            Self.run(inkData: inkData, source: source, folder: folder, destination: destination, report: report)
        }
        task = work
        Task { [weak self] in
            let ok = await work.value
            guard let self, !work.isCancelled else { return }
            state = ok ? .finished(destination) : .failed
        }
    }

    private nonisolated static func run(inkData: Data, source: URL, folder: URL, destination: URL,
                                        report: @Sendable (Int, Int) -> Void) -> Bool {
        do {
            let ink = try PDFInk(data: inkData)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PDFExporter.export(pdf: source, ink: ink, to: destination) { done, total in
                report(done, total)
                return !Task.isCancelled
            }
            return true
        } catch {
            return false
        }
    }

    private func report(done: Int, total: Int) {
        guard case .running = state else { return }
        state = .running(done: done, total: total)
    }

    /// 存到 PDF 旁邊；同名時自動編號，不覆蓋
    func saveToVault() {
        guard case .finished(let url) = state, savedPath == nil,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return }
        let fs = document.session.vault
        let path = PDFExporter.exportedPath(forPDF: document.path, exists: fs.exists)
        document.session.write(data, to: path)
        savedPath = path
    }

    /// 取消並清掉暫存檔（表單關閉時）
    func discard() {
        task?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// 匯出表單：進度（可取消）→ 分享 / 存進 Vault
struct PDFExportSheet: View {
    let job: PDFExportJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text(L("匯出含標註的 PDF")).font(.headline)
            switch job.state {
            case .running(let done, let total):
                VStack(spacing: 8) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text(total > 0 ? L("第 \(done) / \(total) 頁") : L("準備中…"))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(L("取消"), role: .cancel) { dismiss() }
            case .finished(let url):
                Text(L("標註已壓平：在其他 App 中無法再編輯，但任何閱讀器與列印都會一致。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    ShareLink(item: url) {
                        Label(L("分享…"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if let saved = job.savedPath {
                        Label(L("已存成「\((saved as NSString).lastPathComponent)」"), systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button { job.saveToVault() } label: {
                            Label(L("存到 PDF 所在資料夾"), systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                Button(L("完成")) { dismiss() }
            case .failed:
                Text(L("無法匯出這份 PDF。")).foregroundStyle(.secondary)
                Button(L("關閉")) { dismiss() }
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 380)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isRunning)
        .onAppear { job.start() }
        .onDisappear { job.discard() }
    }

    private var isRunning: Bool {
        if case .running = job.state { true } else { false }
    }
}
