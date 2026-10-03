import CoreGraphics
import ExcalidrawKit
import Foundation

/// 匯出：把原始 PDF 與標註壓平成一份新的 PDF（見 architecture/pdf.md「匯出」）。
/// 只用 CoreGraphics，沒有 UI 依賴，可在背景執行緒執行；大檔（教科書）逐頁處理、逐頁釋放。
enum PDFExporter {
    enum ExportError: Error {
        case cannotRead
        case cannotCreate
        case cancelled
    }

    /// 匯出檔名的後綴慣例（`<檔名>（標註）.pdf`、`<檔名>（標註 2）.pdf`）
    private static let suffix = "標註" // l10n:fixed

    /// 匯出到 Vault 時的檔名：`<檔名>（標註）.pdf`，已存在就改 `（標註 2）`、`（標註 3）`…，絕不覆蓋
    static func exportedPath(forPDF path: String, exists: (String) -> Bool) -> String {
        let ns = path as NSString
        let folder = ns.deletingLastPathComponent
        let base = (ns.lastPathComponent as NSString).deletingPathExtension
        var n = 1
        while true {
            let tag = n == 1 ? "（\(suffix)）" : "（\(suffix) \(n)）" // l10n:fixed
            let candidate = (folder as NSString).appendingPathComponent("\(base)\(tag).pdf")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// 逐頁畫原頁面（含 cropBox、`rotation`）再以向量畫標註。`progress(完成頁數, 總頁數)` 回傳 false 取消，
    /// 取消與失敗都不會留下半成品。輸出頁面的尺寸是旋轉後的 cropBox。
    static func export(pdf source: URL, ink: PDFInk, to destination: URL,
                       progress: (_ done: Int, _ total: Int) -> Bool = { _, _ in true }) throws {
        guard let document = CGPDFDocument(source as CFURL), !document.isEncrypted || document.unlockWithPassword("")
        else { throw ExportError.cannotRead }
        let total = document.numberOfPages
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(destination as CFURL, mediaBox: &defaultBox, nil) else { throw ExportError.cannotCreate }
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: destination) } }

        for index in 0..<total {
            guard progress(index, total) else { ctx.closePDF(); throw ExportError.cancelled }
            guard let page = document.page(at: index + 1) else { continue }
            autoreleasepool {
                draw(page, ink: ink, pageIndex: index, in: ctx)
            }
        }
        ctx.closePDF()
        finished = true
        _ = progress(total, total)
    }

    private static func draw(_ page: CGPDFPage, ink: PDFInk, pageIndex: Int, in ctx: CGContext) {
        let cropBox = page.getBoxRect(.cropBox)
        let geometry = PDFPageGeometry(cropBox: cropBox, rotation: Int(page.rotationAngle))
        var mediaBox = CGRect(origin: .zero, size: geometry.displaySize)
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)]
        ctx.beginPDFPage(info as CFDictionary)
        defer { ctx.endPDFPage() }

        ctx.saveGState()
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: cropBox)
        ctx.drawPDFPage(page)
        ctx.restoreGState()

        let scene = ink.scene(page: pageIndex)
        let renderer = SceneRenderer(scene: scene)
        guard !renderer.elements.isEmpty else { return }
        // 標註座標：原點左上、y 向下；先翻成 y 向下的顯示座標，再套頁面旋轉
        ctx.saveGState()
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(geometry.displayTransform)
        renderer.draw(in: ctx, pixelScale: 4)
        ctx.restoreGState()
    }
}
