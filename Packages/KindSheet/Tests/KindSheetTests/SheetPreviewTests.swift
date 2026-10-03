import Foundation
import ImageIO
import Testing
@testable import KindSheet

/// 列表縮圖與 `![[x.csv]]` 嵌入用的 PNG
struct SheetPreviewTests {
    @Test func drawsFirstRowsAndColumns() throws {
        var csv = "名稱,數量,單價,日期,備註,分類,多出來的欄\n"
        for i in 1...20 { csv += "項目 \(i),\(i),\(i * 10),2026-10-0\(i % 9 + 1),\"多行\n備註\",A,x\n" }
        let preview = SheetPreview(delimiter: CSVKind.delimiter).makePreview(Data(csv.utf8))
        #expect(preview.lines == ["名稱", "數量", "單價", "日期"])
        let png = try #require(preview.image)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // 標題列 + 7 列資料；6 欄，每欄在 min…max 之間
        let height = (SheetPreview.headerHeight + SheetPreview.rowHeight * 7) * SheetPreview.pixelScale
        #expect(CGFloat(image.height) == height.rounded(.up))
        #expect(CGFloat(image.width) >= SheetPreview.minColumnWidth * 6 * SheetPreview.pixelScale)
        #expect(CGFloat(image.width) <= (SheetPreview.maxColumnWidth * 6 * SheetPreview.pixelScale).rounded(.up))
    }

    @Test func tsvUsesTabs() {
        let preview = SheetPreview(delimiter: TSVKind.delimiter).makePreview(Data("a,b\tc\n1\t2\n".utf8))
        #expect(preview.lines == ["a,b", "c"])
        #expect(preview.image != nil)
    }

    @Test func emptyFileHasNoImage() {
        let preview = SheetPreview(delimiter: CSVKind.delimiter).makePreview(Data())
        #expect(preview.image == nil)
        #expect(preview.lines.isEmpty)
    }
}
