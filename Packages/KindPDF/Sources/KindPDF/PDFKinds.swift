import EasyNotesCore
import Foundation
import PDFKit

/// .pdf：不透明檔案（內容不同 → 衝突副本）。原始 PDF 不改動，標註在 `.pdf.ink`。
public enum PDFKind: DocumentKind {
    public static let id = "pdf"
    public static let fileExtensions = ["pdf"]

    /// 不能建立新 PDF（只能匯入）
    public static func template(title: String) -> Data { Data() }

    /// 只有標題與摘要；PDF 文字與便利貼文字暫不索引
    public static func index(_ data: Data, fileName: String) -> IndexEntry {
        let pages = PDFDocument(data: data)?.pageCount
        return IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: "",
                          summary: pages.map { "\($0) 頁" })
    }
}

/// .pdf.ink：PDF 的標註旁檔。依頁合併；Core 視它為 `.pdf` 的伴隨檔。
public enum PDFInkKind: DocumentKind {
    public static let id = "pdf-ink"
    public static let fileExtensions = ["pdf.ink"]

    public static func template(title: String) -> Data {
        (try? PDFInk().data()) ?? Data()
    }

    public static func index(_ data: Data, fileName: String) -> IndexEntry {
        IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: "")
    }

    /// 去掉 `.ink` 就是主檔 `<檔名>.pdf`
    public static func companionOf(_ path: String) -> String? {
        path.lowercased().hasSuffix(".pdf.ink") ? String(path.dropLast(4)) : nil
    }

    /// 任一邊不是合法的 `.pdf.ink` 才交給衝突副本
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        if local == remote { return local }
        guard let l = try? PDFInk(data: local), let r = try? PDFInk(data: remote) else { return nil }
        return try? PDFInk.merge(local: l, remote: r).data()
    }
}
