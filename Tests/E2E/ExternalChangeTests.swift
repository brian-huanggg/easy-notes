import XCTest

/// 外部工具（Finder、VS Code、Claude Code）直接改 Vault：App 即時反映，並交給外掛的 ContentFixer。
/// macOS 由 FSEvents 觸發；iOS 在回到前景時比對（`nudgeExternalScan`）。
final class ExternalChangeTests: E2ETestCase {
    @MainActor
    func testExternallyCreatedFileAppears() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))

        vault.write("# Claude 寫的筆記\n", to: "Claude 寫的筆記.md")
        app.nudgeExternalScan()

        app.waitFor(A11yID.List.document("Claude 寫的筆記.md"))
    }

    @MainActor
    func testExternallyDeletedFileDisappears() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.meeting))

        vault.remove(Fixture.Path.meeting)
        app.nudgeExternalScan()

        XCTAssertTrue(waitUntil { !app.element(A11yID.List.document(Fixture.Path.meeting)).exists })
    }

    /// 開著的筆記被外部修改：編輯器套用遠端內容（applyRemote），不需要重新開啟
    @MainActor
    func testExternalEditReachesOpenEditor() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault, open: Fixture.Path.plan)
        app.waitForEditor("markdown")
        XCTAssertTrue(app.editorShows("第一行"), "編輯器沒有顯示檔案內容")

        let token = "external-edit-77"
        vault.write("# 專案計畫\n\n第一行\n\(token)\n第三行\n", to: Fixture.Path.plan)
        app.nudgeExternalScan()

        XCTAssertTrue(app.editorShows(token), "外部修改沒有出現在開著的編輯器")
        // 等過編輯器的存檔週期（300ms）：App 不會把舊內容寫回去
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(vault.read(Fixture.Path.plan)?.contains(token), true)
    }

    /// Claude Code 只寫 `::` 卡片語法，`^id` 由 App（Flashcards 的 ContentFixer）補上
    @MainActor
    func testCardWithoutIDGetsOne() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.cards))

        XCTAssertTrue(waitUntil { vault.read(Fixture.Path.cards)?.contains("ephemeral :: 短暫的 ^c-") == true },
                      "卡片沒有補上 ^id：\(vault.read(Fixture.Path.cards) ?? "")")
        // 只補 id，其餘內容不變
        XCTAssertEqual(vault.read(Fixture.Path.cards)?.hasPrefix("# 單字卡\n\nephemeral :: 短暫的 ^c-"), true)
    }
}
