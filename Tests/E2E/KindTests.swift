import XCTest

/// 每個外掛註冊的類型都能從列表開啟，App 不會當掉；外掛面板（複習）可以開啟
final class KindTests: E2ETestCase {
    @MainActor
    func testMarkdownOpens() { open(Fixture.Path.welcome, expecting: "markdown") }

    @MainActor
    func testWhiteboardOpens() { open(Fixture.Path.board, expecting: "ink") }

    @MainActor
    func testSheetOpens() { open(Fixture.Path.budget, expecting: "csv") }

    @MainActor
    func testPDFOpens() { open(Fixture.Path.handout, expecting: "pdf") }

    @MainActor
    func testReviewPanelOpens() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        app.tap(A11yID.Sidebar.panel("review"))
        app.waitFor(A11yID.panel("review"))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 開啟後不修改內容：只是看，不應該改寫使用者的檔案（開放格式原樣保留）
    @MainActor
    private func open(_ path: String, expecting kindID: String, file: StaticString = #filePath, line: UInt = #line) {
        let vault = TestVault()
        Fixture.standard(vault)
        let original = try? Data(contentsOf: vault.url(path))
        let app = launch(vault)

        app.tap(A11yID.List.document(path), file: file, line: line)
        app.waitForEditor(kindID, file: file, line: line)
        XCTAssertFalse(app.element(A11yID.Editor.unsupported).exists, file: file, line: line)

        // 回到列表（觸發編輯器 flush），檔案內容不變
        app.tap(A11yID.Toolbar.back, file: file, line: line)
        app.waitFor(A11yID.List.document(path), file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try? Data(contentsOf: vault.url(path)), original, "開啟 \(path) 後檔案被改寫", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }
}
