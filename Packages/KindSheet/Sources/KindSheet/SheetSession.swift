import EasyNotesUI
import Foundation
import Observation

/// 開啟中的表格：記憶體中的 `SheetDocument`、自己的 RevoGrid WebView 與寫檔。
/// 每次開檔建立、關閉後釋放（不與 Markdown 的預熱 WebView 共用），WebContent process 跟著結束。
/// JS 在儲存格編輯結束時送 `edit`，這裡套到模型上，停止編輯 300 ms 後寫檔。
@MainActor @Observable
final class SheetSession {
    let path: String
    private(set) var encoding: SheetDocument.TextEncoding

    var isReadOnly: Bool { encoding != .utf8 }

    @ObservationIgnored let host: WebEditorHost
    @ObservationIgnored private var document: SheetDocument
    @ObservationIgnored private let session: any DocumentSession
    /// 磁碟上的內容（最後一次讀到或寫出的）；外部變動以它為合併基準
    @ObservationIgnored private var lastData: Data
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(path: String, delimiter: UInt8, session: any DocumentSession) {
        self.path = path
        self.session = session
        let data = session.readData(path)
        let document = SheetDocument(data: data, delimiter: delimiter)
        lastData = data
        self.document = document
        encoding = document.encoding
        host = WebEditorHost(page: Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Sheet"),
                             stylesheet: ThemeCSS.stylesheet())
        host.onReady = { [weak self] in self?.sendLoad() }
        host.onMessage = { [weak self] type, msg in self?.receive(type, msg) }
    }

    // MARK: Swift → JS

    /// 整份重新載入（開檔、編碼改變、模型與畫面對不上時）；清掉 JS 端的 Undo
    private func sendLoad() {
        host.call("sheet.load(json)", ["json": payload(readOnly: isReadOnly)])
    }

    func exec(_ command: String) {
        host.call("sheet.exec(command)", ["command": command])
    }

    func focus() {
        host.call("sheet.focus()")
    }

    private struct Payload: Encodable {
        struct Row: Encodable {
            let id: Int
            let cells: [String]
        }

        let rows: [Row]
        let readOnly: Bool?
    }

    /// 1 萬列也只是一次 JSON 字串；JS 端 `JSON.parse`，比逐一轉換 NSDictionary 快
    private func payload(readOnly: Bool?) -> String {
        let rows = document.records.map { Payload.Row(id: $0.id, cells: $0.fields) }
        let data = (try? JSONEncoder().encode(Payload(rows: rows, readOnly: readOnly))) ?? Data("{\"rows\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: JS → Swift

    private func receive(_ type: String, _ msg: [String: Any]) {
        guard type == "edit", let json = msg["ops"] as? String else { return }
        do {
            let ops = try JSONDecoder().decode([SheetOp].self, from: Data(json.utf8))
            try document.apply(ops)
            scheduleSave()
        } catch {
            // 模型與畫面對不上（例如外部變動刪掉了 Undo 要改的列）：以模型為準重新載入
            print("[sheet] edit failed: \(error)")
            scheduleSave()
            sendLoad()
        }
    }

    // MARK: 寫檔

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        saveTask?.cancel()
        saveTask = nil
        let data = document.data()
        guard data != lastData else { return }
        lastData = data
        session.write(data, to: path)
    }

    /// 改名、刪除、進背景、關閉前：結束編輯中的儲存格並立即寫檔
    func flush() async {
        await host.callAndWait("sheet.flush()")
        save()
    }

    // MARK: 外部變動

    /// 同步或外部工具（Claude Code）改了檔案：還沒寫出的編輯以三方合併保留，
    /// 合併不了就以外部內容為準（未寫出的編輯最多是 300 ms 內的）。畫面更新但保留選取
    func externalChange(_ data: Data) {
        guard data != lastData else { return }
        saveTask?.cancel()
        saveTask = nil
        let local = document.data()
        var merged = data
        if local != lastData,
           let result = SheetDocument.merge(base: lastData, local: local, remote: data, delimiter: document.style.delimiter) {
            merged = result
        }
        lastData = data
        let wasReadOnly = isReadOnly
        document.replaceContent(with: merged)
        encoding = document.encoding
        if merged != data { save() }
        if wasReadOnly != isReadOnly {
            sendLoad()
        } else {
            host.call("sheet.applyRemote(json)", ["json": payload(readOnly: nil)])
        }
    }

    /// Big5 檔案改存成 UTF-8（內容不變），之後可以編輯
    func convertToUTF8() {
        guard let utf8 = SheetDocument.convertToUTF8(lastData) else { return }
        document.replaceContent(with: utf8)
        encoding = document.encoding
        lastData = utf8
        session.write(utf8, to: path)
        sendLoad()
    }
}

/// 開啟中的表格登記處，同時是 App → 外掛的通知入口（`EditorController`）
@MainActor
final class SheetController: EditorController {
    static let shared = SheetController()

    private var sheets: [String: SheetSession] = [:]
    /// 「表格」選單指令的對象：最後開啟的表格
    private weak var active: SheetSession?

    /// 編輯器開啟表格時呼叫；同一個路徑共用同一份
    func open(_ path: String, delimiter: UInt8, session: any DocumentSession) -> SheetSession {
        let sheet = sheets[path] ?? SheetSession(path: path, delimiter: delimiter, session: session)
        sheets[path] = sheet
        active = sheet
        return sheet
    }

    /// 編輯器關閉：先寫檔，寫完才釋放 WebView
    func release(_ path: String) {
        guard let sheet = sheets.removeValue(forKey: path) else { return }
        if active === sheet { active = sheets.values.first }
        Task { await sheet.flush() }
    }

    func exec(_ command: String) {
        active?.exec(command)
    }

    func flush() async {
        for sheet in sheets.values { await sheet.flush() }
    }

    func externalChange(path: String, data: Data) {
        sheets[path]?.externalChange(data)
    }

    func close(path: String) {
        release(path)
    }
}
