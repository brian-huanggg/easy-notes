import Foundation

// l10n:fixed-file Sample content for first launch; chosen by UI language at creation time, and the user's own files afterwards
enum Seed {
    private static var usesChinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
    }

    /// Has the matching plugin produce a blank template (skipped when no plugin is registered)
    static var templates: [(path: String, title: String)] {
        usesChinese ? [("Spike/手寫測試.excalidraw", "手寫測試")]
                    : [("Spike/Handwriting Test.excalidraw", "Handwriting Test")]
    }

    static var files: [(String, String)] { usesChinese ? chineseFiles : englishFiles }

    private static let englishFiles: [(String, String)] = [
        ("Welcome to EasyNotes.md", """
        # Welcome to EasyNotes

        Every note is a **real file** you can open in any editor. The *Markdown* syntax of a line only shows while the cursor is on it.

        ## Try it

        - [ ] Click this checkbox
        - [x] A completed item
        - Click [[Spike Checklist]] to jump to another note
        - Click [[A note that doesn't exist yet]] to create it automatically

        > Quote block: knowledge should belong to you, not to an app.

        Inline `code`, ~~strikethrough~~, **bold**, *italic*.

        ```swift
        let vault = VaultFS(root: url)
        ```

        #getting-started #easynotes
        """),
        ("Spike/Spike Checklist.md", """
        # Spike Checklist

        ## S1: CodeMirror 6 in WKWebView

        - [ ] iOS Zhuyin input: type "知識管理系統" in one go, with no dropped or duplicated characters
        - [ ] macOS Zhuyin input: same as above
        - [ ] The candidate window is positioned correctly and follows the cursor
        - [ ] Switching notes takes < 50ms (the last switch time shows at the top right)
        - [ ] Typing stays smooth after pressing "Benchmark 10k lines"
        - [ ] Open the .md in Finder: the content matches what you typed (no reformatting)
        - [ ] The native formatting toolbar appears above the iPad keyboard
        - [ ] Dark mode looks right

        ## S2: PencilKit ⇄ Excalidraw

        - [x] Unit tests: points, pressure, and timing round-trip losslessly (`swift test`)
        - [ ] Open [[Handwriting Test]] on an iPad and draw a few strokes
        - [ ] Drag `Handwriting Test.excalidraw` onto excalidraw.com and check the strokes render correctly
        """),
    ]

    private static let chineseFiles: [(String, String)] = [
        ("歡迎使用 EasyNotes.md", """
        # 歡迎使用 EasyNotes

        每一筆筆記都是一個**真實的檔案**，可以用任何編輯器打開。游標移到某一行時，才會顯示它的 *Markdown* 語法。

        ## 試試看

        - [ ] 點一下這個核取方塊
        - [x] 已完成的項目
        - 點擊 [[Spike 驗收清單]] 跳到另一篇筆記
        - 點擊 [[還不存在的筆記]] 會自動建立它

        > 引用區塊：知識應該屬於你，而不是某個 App。

        行內 `code`、~~刪除線~~、**粗體**、*斜體*。

        ```swift
        let vault = VaultFS(root: url)
        ```

        #入門 #easynotes
        """),
        ("Spike/Spike 驗收清單.md", """
        # Spike 驗收清單

        ## S1：CodeMirror 6 在 WKWebView

        - [ ] iOS 注音輸入：連續輸入「知識管理系統」，無吃字、無重複
        - [ ] macOS 注音輸入：同上
        - [ ] 選字視窗位置正確，跟著游標
        - [ ] 切換筆記 < 50ms（右上角顯示最近一次切換時間）
        - [ ] 按「Benchmark 1 萬行」後打字不卡
        - [ ] 用 Finder 開啟 .md，內容與輸入完全一致（沒有被改寫格式）
        - [ ] iPad 鍵盤上方出現原生格式工具列
        - [ ] 深色模式正確

        ## S2：PencilKit ⇄ Excalidraw

        - [x] 單元測試：點、壓力、時間來回無損（`swift test`）
        - [ ] 在 iPad 開啟 [[手寫測試]] 手寫幾筆
        - [ ] 把 `手寫測試.excalidraw` 拖到 excalidraw.com，筆畫正確顯示
        """),
    ]
}
