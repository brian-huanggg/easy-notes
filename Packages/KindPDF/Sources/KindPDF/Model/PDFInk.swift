import EasyNotesCore
import ExcalidrawKit
import Foundation

/// `<檔名>.pdf.ink`：依頁碼分組的 Excalidraw elements。頁碼從 0 開始，沒有標註的頁不寫。
/// 以原始 JSON 字典保存，未知欄位與元素原樣寫回。
public struct PDFInk {
    public static let type = "easynotes-pdf-ink"
    public static let version = 1

    private var raw: [String: Any]

    /// 空白標註；`pdfHash` 是 PDF 內容的 SHA-256（小寫 hex）
    public init(pdfHash: String = "") {
        self.init(raw: ["type": Self.type, "version": Self.version, "pdfHash": pdfHash,
               "pages": [String: Any](), "files": [String: Any]()])
    }

    private init(raw: [String: Any]) {
        self.raw = raw
    }

    /// 空資料視為空白標註；不是 `easynotes-pdf-ink` 就丟錯
    public init(data: Data) throws {
        if data.isEmpty { self.init(); return }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["type"] as? String == Self.type
        else { throw CocoaError(.fileReadCorruptFile) }
        self.init(raw: dict)
    }

    /// 旁檔路徑：`<檔名>.pdf` + `.ink`
    public static func path(forPDF pdfPath: String) -> String {
        pdfPath + ".ink"
    }

    /// `pdfHash`：PDF 內容的 SHA-256（小寫 hex，與同步層的內容 hash 相同格式）
    public static func hash(of pdf: Data) -> String {
        SyncEngine.sha256(pdf)
    }

    public func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
    }

    public var pdfHash: String {
        get { raw["pdfHash"] as? String ?? "" }
        set { raw["pdfHash"] = newValue }
    }

    private var pageDicts: [String: Any] { raw["pages"] as? [String: Any] ?? [:] }

    /// 有標註的頁碼（升冪）
    public var pageIndexes: [Int] {
        pageDicts.keys.compactMap { Int($0) }.sorted()
    }

    /// 該頁的 elements（含墓碑）；沒有標註回傳空陣列
    public func elements(page: Int) -> [[String: Any]] {
        (pageDicts[String(page)] as? [String: Any])?["elements"] as? [[String: Any]] ?? []
    }

    /// 取代某頁的 elements；空陣列代表整頁移除。頁的其他欄位保留
    public mutating func setElements(_ elements: [[String: Any]], page: Int) {
        var pages = pageDicts
        let key = String(page)
        if elements.isEmpty {
            pages[key] = nil
        } else {
            var entry = pages[key] as? [String: Any] ?? [:]
            entry["elements"] = elements
            pages[key] = entry
        }
        raw["pages"] = pages
    }

    /// 某頁當成一個 `ExcalidrawScene`（渲染、`inkStrokes`、`replaceInk`、便利貼編輯都沿用白板的）。
    /// 圖片檔 `files` 為整份共用。
    public func scene(page: Int) -> ExcalidrawScene {
        var scene = ExcalidrawScene()
        scene.raw["elements"] = elements(page: page)
        scene.raw["files"] = raw["files"] as? [String: Any] ?? [:]
        return scene
    }

    /// 把場景寫回某頁（只取 elements；`files` 取聯集）
    public mutating func setScene(_ scene: ExcalidrawScene, page: Int) {
        setElements(scene.elements, page: page)
        let mine = raw["files"] as? [String: Any] ?? [:]
        let theirs = scene.raw["files"] as? [String: Any] ?? [:]
        raw["files"] = mine.merging(theirs) { a, _ in a }
    }

    /// 沒有任何未刪除的元素
    public var isEmpty: Bool {
        pageIndexes.allSatisfy { page in elements(page: page).allSatisfy { $0["isDeleted"] as? Bool == true } }
    }

    // MARK: 合併

    /// 依頁合併：每頁用白板的元素合併（`id` + `version`）；只在一邊出現的頁直接保留；
    /// `files` 取聯集；`pdfHash` 保留本機的（本機為空才採用遠端的）。
    public static func merge(local: PDFInk, remote: PDFInk) -> PDFInk {
        var merged = local
        for page in Set(local.pageIndexes + remote.pageIndexes).sorted() {
            let l = local.elements(page: page), r = remote.elements(page: page)
            if r.isEmpty { continue }
            if l.isEmpty { merged.setElements(r, page: page); continue }
            var a = ExcalidrawScene(), b = ExcalidrawScene()
            a.raw["elements"] = l
            b.raw["elements"] = r
            merged.setElements(ExcalidrawScene.merge(local: a, remote: b).elements, page: page)
        }
        let localFiles = local.raw["files"] as? [String: Any] ?? [:]
        let remoteFiles = remote.raw["files"] as? [String: Any] ?? [:]
        merged.raw["files"] = localFiles.merging(remoteFiles) { mine, _ in mine }
        if merged.pdfHash.isEmpty { merged.pdfHash = remote.pdfHash }
        return merged
    }

    /// 元素與 `files` 相同（不看 `pdfHash` 與格式）
    public func hasSameContent(as other: PDFInk) -> Bool {
        pageIndexes == other.pageIndexes
            && pageIndexes.allSatisfy { page in
                let a = elements(page: page), b = other.elements(page: page)
                return a.count == b.count && zip(a, b).allSatisfy { NSDictionary(dictionary: $0).isEqual(to: $1) }
            }
            && NSDictionary(dictionary: raw["files"] as? [String: Any] ?? [:])
                .isEqual(to: other.raw["files"] as? [String: Any] ?? [:])
    }
}
