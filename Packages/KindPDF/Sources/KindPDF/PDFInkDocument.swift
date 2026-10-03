import EasyNotesCore
import EasyNotesUI
import ExcalidrawKit
import Foundation
import Observation

/// 開啟中的 PDF：原始 PDF（唯讀）+ 記憶體中的標註（`PDFInk`）與旁檔寫入。
/// 檢視器改它，`PDFController` 把外部變動（同步、Claude Code）併進它，兩邊共用同一份標註。
@MainActor @Observable
final class PDFInkDocument {
    let path: String
    var inkPath: String { PDFInk.path(forPDF: path) }
    private(set) var ink: PDFInk
    /// 目前 PDF 內容的 SHA-256；背景算完之前為 nil
    private(set) var pdfHash: String?
    /// PDF 檔被換掉（同步、外部工具）時遞增，檢視器據此重新載入
    private(set) var pdfRevision = 0

    /// 標註改變（外部合併、編輯）：`pages` 為改變的頁，nil = 全部
    @ObservationIgnored var onInkChange: ((_ pages: Set<Int>?) -> Void)?
    /// 把檢視器裡尚未寫回的內容（編輯中的便利貼文字）併進標註並存檔
    @ObservationIgnored var flushHandler: (() -> Void)?
    @ObservationIgnored let session: any DocumentSession
    @ObservationIgnored private var lastData: Data?
    @ObservationIgnored private(set) var hasUnsavedEdits = false
    @ObservationIgnored private var hashTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(path: String, session: any DocumentSession) {
        self.path = path
        self.session = session
        ink = PDFInk()
        loadInk()
        computeHash(claimOrphan: true)
    }

    var pdfURL: URL { session.vault.url(for: path) }

    /// 旁檔記錄的 `pdfHash` 與目前的 PDF 不同（PDF 被換掉）：標註可能錯位
    var hashMismatch: Bool {
        guard let pdfHash, !ink.pdfHash.isEmpty else { return false }
        return ink.pdfHash != pdfHash
    }

    func scene(page: Int) -> ExcalidrawScene {
        ink.scene(page: page)
    }

    // MARK: 編輯

    /// 改記憶體中的某頁、標記待存（拖曳中逐幀修改）；停止操作 500 ms 後才寫入（或由 `commit` 立即寫入）
    func edit<T>(page: Int, _ body: (inout ExcalidrawScene) -> T) -> T {
        var scene = ink.scene(page: page)
        let result = body(&scene)
        ink.setScene(scene, page: page)
        hasUnsavedEdits = true
        onInkChange?([page])
        scheduleCommit()
        return result
    }

    private func scheduleCommit() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// 立即寫入待存的修改。第一次建立旁檔時記下目前的 `pdfHash`
    func commit() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedEdits else { return }
        hasUnsavedEdits = false
        if ink.pdfHash.isEmpty, let pdfHash { ink.pdfHash = pdfHash }
        guard let data = try? ink.data(), data != lastData else { return }
        write(data)
    }

    func flush() {
        flushHandler?()
        commit()
    }

    /// 「保留標註」：PDF 被換掉後，以目前的 PDF 為準
    func keepAnnotations() {
        guard let pdfHash, ink.pdfHash != pdfHash else { return }
        ink.pdfHash = pdfHash
        if let data = try? ink.data() { write(data) }
    }

    // MARK: 外部變動

    /// PDF 或旁檔被外部修改或同步
    func externalChange(path changed: String, data: Data) {
        if changed == path {
            pdfRevision += 1
            computeHash(claimOrphan: false)
            return
        }
        guard changed == inkPath, data != lastData, let remote = try? PDFInk(data: data) else { return }
        flush() // 先把編輯中的內容收進標註，再合併
        let merged = PDFInk.merge(local: ink, remote: remote)
        ink = merged
        if !merged.hasSameContent(as: remote) || merged.pdfHash != remote.pdfHash, let out = try? merged.data() {
            write(out)
        } else {
            lastData = data
        }
        onInkChange?(nil)
    }

    // MARK: 讀寫

    private func loadInk() {
        guard session.vault.exists(inkPath) else { return }
        let data = session.readData(inkPath)
        ink = (try? PDFInk(data: data)) ?? PDFInk()
        lastData = data
    }

    /// 背景讀 PDF 算 hash；沒有旁檔時順便認領外部改名留下的孤兒旁檔
    private func computeHash(claimOrphan: Bool) {
        hashTask?.cancel()
        let fs = session.vault, path = path
        hashTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (hash: String, orphan: String?)? in
                guard let data = try? fs.read(path) else { return nil }
                let orphan = claimOrphan ? (try? PDFInk.claimOrphan(for: path, pdfData: data, in: fs)) ?? nil : nil
                return (PDFInk.hash(of: data), orphan)
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            if let orphan = result.orphan {
                session.fileMoved(from: orphan, to: inkPath)
                loadInk()
                onInkChange?(nil)
            }
            pdfHash = result.hash
        }
    }

    private func write(_ data: Data) {
        lastData = data
        session.write(data, to: inkPath)
    }
}

/// 開啟中的 PDF 登記處，同時是 App → 外掛的通知入口（`EditorController`）
@MainActor
final class PDFController: EditorController {
    static let shared = PDFController()

    private var documents: [String: PDFInkDocument] = [:]

    /// 檢視器開啟 PDF 時呼叫；同一個路徑共用同一份
    func open(_ path: String, session: any DocumentSession) -> PDFInkDocument {
        if let doc = documents[path] { return doc }
        let doc = PDFInkDocument(path: path, session: session)
        documents[path] = doc
        return doc
    }

    func flush() async {
        documents.values.forEach { $0.flush() }
    }

    /// 旁檔的變動交給它的主檔
    func externalChange(path: String, data: Data) {
        let main = PDFInkKind.companionOf(path) ?? path
        documents[main]?.externalChange(path: path, data: data)
    }

    func close(path: String) {
        documents[path] = nil
    }
}
