// l10n:fixed-file 測試資料（檔名、內容）不是介面文字
import CoreGraphics
import Foundation

/// 測試用的 Vault 內容。檔名與內容刻意含中文（使用者的實際情況）；
/// 需要在 UI 上輸入的字只用 ASCII，因為 XCUITest 的 `typeText` 不經過輸入法（注音另外驗證，見 Roadmap）。
enum Fixture {
    /// 只出現在「歡迎.md」的 ASCII 字，用來測試搜尋
    static let searchToken = "zebra42"

    enum Path {
        static let welcome = "歡迎.md"
        static let plan = "Projects/專案計畫.md"
        static let meeting = "Projects/會議記錄.md"
        static let board = "Projects/架構圖.excalidraw"
        static let budget = "Projects/預算.csv"
        static let handout = "Study/講義.pdf"
        static let cards = "Study/單字卡.md"
        static let guide = "CLAUDE.md"
    }

    /// 兩個空間（Projects、Study）、每種外掛一個檔案
    static func standard(_ vault: TestVault) {
        vault.write("# EasyNotes Vault\n", to: Path.guide) // 已存在就不會被 App 改寫
        vault.write("""
            # 歡迎

            連到 [[專案計畫]]。

            搜尋用的字：\(searchToken)

            #入門
            """, to: Path.welcome)
        vault.write("# 專案計畫\n\n第一行\n第二行\n第三行\n", to: Path.plan)
        vault.write("# 會議記錄\n\n- 決議：見 [[專案計畫]]\n", to: Path.meeting)
        vault.write(whiteboard(elements: 3), to: Path.board)
        vault.write("項目,金額\n午餐,120\n書,450\n", to: Path.budget)
        vault.write(pdf(pages: 2), to: Path.handout)
        // 沒有 ^id 的卡片：App 的 ContentFixer 會補上
        vault.write("# 單字卡\n\nephemeral :: 短暫的\n", to: Path.cards)
    }

    /// 文件數（列表頁「所有文件」的數量；`.excalidraw`、`.csv`、`.pdf` 都算）
    static let standardDocumentCount = 8

    // MARK: 白板

    /// Excalidraw 格式（與 scripts/whiteboard-stress.py 相同的欄位），矩形與文字交錯；固定內容，每次相同
    static func whiteboard(elements count: Int) -> Data {
        let elements: [[String: Any]] = (0..<count).map { i in
            let x = Double(i % 40) * 200, y = Double(i / 40) * 150
            var element: [String: Any] = [
                "id": "e2e-\(i)", "type": i % 2 == 0 ? "rectangle" : "text", "x": x, "y": y,
                "width": 160, "height": i % 2 == 0 ? 100 : 25, "angle": 0,
                "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid",
                "strokeWidth": 2, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "groupIds": [String](),
                "frameId": NSNull(), "roundness": NSNull(), "seed": i + 1, "version": 1, "versionNonce": i + 1,
                "isDeleted": false, "boundElements": NSNull(), "updated": 0, "link": NSNull(), "locked": false,
            ]
            if i % 2 == 1 {
                let text = "節點 \(i)"
                element.merge([
                    "text": text, "originalText": text, "fontSize": 20, "fontFamily": 2, "textAlign": "left",
                    "verticalAlign": "top", "containerId": NSNull(), "autoResize": true, "lineHeight": 1.25,
                ]) { $1 }
            }
            return element
        }
        let scene: [String: Any] = [
            "type": "excalidraw", "version": 2, "source": "easynotes-e2e", "elements": elements,
            "appState": ["viewBackgroundColor": "#ffffff", "gridSize": NSNull()], "files": [String: Any](),
        ]
        return try! JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
    }

    // MARK: PDF

    /// 每頁一個色塊的 A4 PDF（CoreGraphics，iOS 與 macOS 共用）
    static func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 60, y: 700 - Double(page) * 40, width: 300, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
