import EasyNotesUI
import Foundation
import Observation

/// 開啟中的白板：記憶體中的場景與寫檔。編輯器改它，`WhiteboardController` 把外部變動併進它，
/// 兩邊共用同一份場景，外部寫入（同步、Claude Code）才不會被編輯器的舊場景覆蓋。
@MainActor @Observable
final class BoardDocument {
    let path: String
    private(set) var scene: ExcalidrawScene
    /// 外部變動併入場景之後呼叫（編輯器據此更新畫面）
    @ObservationIgnored var onExternalChange: (() -> Void)?
    /// 把編輯器裡尚未寫回的內容併進場景並存檔（例如 `PKCanvasView` 的筆畫）
    @ObservationIgnored var flushHandler: (() -> Void)?
    @ObservationIgnored private let session: any DocumentSession
    @ObservationIgnored private var lastData: Data?

    init(path: String, session: any DocumentSession) {
        self.path = path
        self.session = session
        let data = session.readData(path)
        scene = (try? ExcalidrawScene(data: data)) ?? ExcalidrawScene()
        lastData = data
    }

    /// 修改場景；內容有變才寫檔
    func commit(_ body: (inout ExcalidrawScene) -> Void) {
        let before = try? scene.data()
        body(&scene)
        guard let data = try? scene.data(), data != before else { return }
        write(data)
    }

    /// 立即把編輯器的待存內容寫回（改名、刪除、進背景前）
    func flush() {
        flushHandler?()
    }

    /// 檔案被外部修改或同步：依元素 id + version 併進記憶體中的場景。
    /// 本地有、磁碟沒有的內容（合併後與磁碟不同）寫回，其他人的格式與順序不動。
    func externalChange(_ data: Data) {
        guard data != lastData, let remote = try? ExcalidrawScene(data: data) else { return }
        flush() // 先把畫布上未存的筆畫收進場景，再合併
        let merged = ExcalidrawScene.merge(local: scene, remote: remote)
        scene = merged
        if !merged.hasSameContent(as: remote), let out = try? merged.data() {
            write(out)
        } else {
            lastData = data
        }
        onExternalChange?()
    }

    private func write(_ data: Data) {
        lastData = data
        session.write(data, to: path)
    }
}

/// 開啟中的白板登記處，同時是 App → 外掛的通知入口（`EditorController`）
@MainActor
final class WhiteboardController: EditorController {
    static let shared = WhiteboardController()

    private var session: (any DocumentSession)?
    private var documents: [String: BoardDocument] = [:]

    func attach(_ session: any DocumentSession) {
        self.session = session
    }

    /// 編輯器開啟白板時呼叫；同一個路徑共用同一份
    func open(_ path: String, session: any DocumentSession) -> BoardDocument {
        if let doc = documents[path] { return doc }
        let doc = BoardDocument(path: path, session: session)
        documents[path] = doc
        return doc
    }

    func flush() async {
        documents.values.forEach { $0.flush() }
    }

    func externalChange(path: String, data: Data) {
        documents[path]?.externalChange(data)
    }

    func close(path: String) {
        documents[path] = nil
    }
}

extension ExcalidrawScene {
    /// 元素與 `files` 相同（不看 `appState` 與格式）
    func hasSameContent(as other: ExcalidrawScene) -> Bool {
        Self.byID(elements).isEqual(Self.byID(other.elements))
            && NSDictionary(dictionary: raw["files"] as? [String: Any] ?? [:])
                .isEqual(to: other.raw["files"] as? [String: Any] ?? [:])
    }

    private static func byID(_ elements: [[String: Any]]) -> NSDictionary {
        NSDictionary(dictionary: Dictionary(elements.compactMap { el in (el["id"] as? String).map { ($0, el) } },
                                            uniquingKeysWith: { a, _ in a }))
    }
}
