import EasyNotesCore
import Foundation

extension PDFInk {
    /// 外部工具改了 PDF 的名字、旁檔留在原地（VaultWatcher 推斷不到改名時）：
    /// 開啟沒有旁檔的 PDF 時，找主檔已不存在、`pdfHash` 相同的孤兒旁檔，搬到這個 PDF 旁邊。
    /// 回傳被認領旁檔的原路徑（呼叫端據此通知同步層搬移）；沒有就回傳 nil
    public static func claimOrphan(for pdfPath: String, pdfData: Data, in fs: VaultFS) throws -> String? {
        let target = path(forPDF: pdfPath)
        guard !fs.exists(target) else { return nil }
        let hash = hash(of: pdfData)
        let orphans = try fs.allFiles(includingCompanions: true).map(\.path).filter { candidate in
            guard let main = fs.kinds.mainFile(ofCompanion: candidate), !fs.exists(main) else { return false }
            return (try? PDFInk(data: fs.read(candidate)))?.pdfHash == hash
        }
        // 同一個 PDF 有多個孤兒時取同資料夾的，其次依路徑排序，結果穩定
        let folder = (pdfPath as NSString).deletingLastPathComponent
        guard let orphan = orphans.min(by: { a, b in
            let sa = (a as NSString).deletingLastPathComponent == folder, sb = (b as NSString).deletingLastPathComponent == folder
            return sa != sb ? sa : a < b
        }) else { return nil }
        try FileManager.default.moveItem(at: fs.url(for: orphan), to: fs.url(for: target))
        return orphan
    }
}
