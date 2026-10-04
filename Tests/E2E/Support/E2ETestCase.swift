import XCTest

/// E2E 測試的共用流程：每個測試一個新的 Vault、App 以測試模式啟動（不同步或用資料夾 backend）。
/// 找元素一律用 `A11yID`（UITestContract.swift，與 App 共用），不用介面文字。
class E2ETestCase: XCTestCase {
    /// App 收到外部修改、寫入檔案、更新索引的等待上限
    static let timeout: TimeInterval = 15

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    enum SyncMode {
        case off
        /// 以資料夾當遠端（見 RemoteDevice）
        case folder(URL)
    }

    /// 建立 Vault（`fixture` 放入初始檔案）並啟動 App
    @MainActor
    func launch(_ vault: TestVault, sync: SyncMode = .off, open path: String? = nil,
                file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        addTeardownBlock { vault.cleanUp() }
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(vault: vault, sync: sync, open: path)
        #if os(iOS)
        // 橫向：NavigationSplitView 同時顯示側邊欄與內容區
        XCUIDevice.shared.orientation = .landscapeLeft
        #endif
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: Self.timeout), "App 沒有啟動", file: file, line: line)
        return app
    }

    static func arguments(vault: TestVault, sync: SyncMode, open path: String?) -> [String] {
        var args = [
            "-\(LaunchKey.vaultRoot)", vault.root.path(percentEncoded: false),
            "-\(LaunchKey.uiTest)", "YES",
            // 介面語言固定，預設檔名（「未命名」）與排序才穩定；找元素不靠文字
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            // macOS 不還原上次的視窗；列表用「列表」排列，依名稱排序
            "-ApplePersistenceIgnoreState", "YES", "-listLayout", "list", "-listSort", "name",
        ]
        switch sync {
        case .off: args += ["-\(LaunchKey.sync)", "off"]
        case .folder(let url): args += ["-\(LaunchKey.syncFolder)", url.path(percentEncoded: false)]
        }
        if let path { args += ["-\(LaunchKey.open)", path] }
        return args
    }
}

// MARK: - 元素

extension XCUIApplication {
    /// 任何類型的元素（按鈕、文字、容器在 macOS 與 iOS 的類型不同）
    func element(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    func waitFor(_ id: String, timeout: TimeInterval = E2ETestCase.timeout,
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = element(id)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "找不到 \(id)", file: file, line: line)
        return element
    }

    func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(id, file: file, line: line).tapOrClick()
    }

    /// 開啟中的編輯器（`A11yID.Editor.container`）
    @discardableResult
    func waitForEditor(_ kindID: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        waitFor(A11yID.Editor.container(kindID), file: file, line: line)
    }

    /// 右鍵（macOS）或長按（iOS）開啟選單，再點 `itemID`。
    /// SwiftUI 的選單項目在某些系統版本不帶 identifier，所以以介面文字作為備援。
    func contextMenu(on element: XCUIElement, select itemID: String, fallbackLabel: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        #if os(macOS)
        element.rightClick()
        let items = menuItems
        #else
        element.press(forDuration: 1.2)
        let items = buttons
        #endif
        var item = items.matching(identifier: itemID).firstMatch
        if !item.waitForExistence(timeout: 3) { item = items[fallbackLabel] }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "選單沒有 \(itemID)", file: file, line: line)
        item.tapOrClick()
    }

    /// 重新命名的對話框：清空後輸入新名稱並確定
    func confirmRename(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        var field = textFields.matching(identifier: A11yID.Rename.field).firstMatch
        if !field.waitForExistence(timeout: 3) {
            field = descendants(matching: .alert).textFields.firstMatch.exists
                ? descendants(matching: .alert).textFields.firstMatch
                : descendants(matching: .dialog).textFields.firstMatch
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "找不到重新命名的欄位", file: file, line: line)
        field.replaceText(name)
        let confirm = buttons.matching(identifier: A11yID.Rename.confirm).firstMatch
        if confirm.waitForExistence(timeout: 2) { confirm.tapOrClick() } else { field.typeText("\n") }
    }

    /// 快速開啟（⌘K）：側邊欄的搜尋按鈕，Mac 與 iPad 相同
    func quickOpen(_ query: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(A11yID.Sidebar.search, file: file, line: line)
        let field = waitFor(A11yID.QuickOpen.field, file: file, line: line)
        field.tapOrClick()
        field.typeText(query)
    }

    /// iOS 沒有 FSEvents：外部修改在 App 回到前景時才比對（與實際使用相同）。macOS 不需要
    func nudgeExternalScan() {
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        activate()
        _ = wait(for: .runningForeground, timeout: E2ETestCase.timeout)
        #endif
    }

    /// 新增筆記：macOS 用「檔案」選單的快捷鍵 ⌘N；iPad 點工具列的新增按鈕（主要動作 = 第一個新增項目）
    func createNote(file: StaticString = #filePath, line: UInt = #line) {
        #if os(macOS)
        typeKey("n", modifierFlags: .command)
        #else
        tap(A11yID.Toolbar.newDocument, file: file, line: line)
        #endif
    }

    // MARK: Markdown 編輯器（WKWebView）

    var editorWebView: XCUIElement { webViews.firstMatch }

    /// 把游標放到文件結尾後輸入（ASCII）。打字只在 JS 內處理，停止輸入 300ms 後才經 Bridge 存檔
    func typeAtEndOfNote(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let web = editorWebView
        XCTAssertTrue(web.waitForExistence(timeout: E2ETestCase.timeout), "找不到編輯器", file: file, line: line)
        let content = web.textViews.firstMatch.exists ? web.textViews.firstMatch : web
        content.tapOrClick()
        #if os(macOS)
        content.typeKey(.downArrow, modifierFlags: .command)
        #else
        // 點內容區下方的空白：CM6 把游標放在最後一行
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        #endif
        content.typeText(text)
    }

    /// 編輯器畫面上出現 `text`（CM6 的每一行在 WebKit 的 accessibility tree 是 staticText）
    func editorShows(_ text: String, timeout: TimeInterval = E2ETestCase.timeout) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return editorWebView.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}

extension XCUIElement {
    func tapOrClick() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }

    /// 清空文字欄位再輸入
    func replaceText(_ text: String) {
        tapOrClick()
        #if os(macOS)
        typeKey("a", modifierFlags: .command)
        typeText(XCUIKeyboardKey.delete.rawValue)
        #else
        let current = (value as? String) ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        #endif
        typeText(text)
    }
}
