import XCTest

/// 非功能預算（core.md「非功能預算」）的量測。比較慢，只在設定 `EASYNOTES_E2E_PERF=1` 時執行：
/// `./scripts/test-e2e.sh perf`（xcodebuild 以 `TEST_RUNNER_EASYNOTES_E2E_PERF=1` 傳給測試程序）。
/// 基準線在 Xcode 的測試報告設定；數字以 Release build 為準，Debug 只看趨勢。
final class PerformanceTests: E2ETestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EASYNOTES_E2E_PERF"] == "1",
                          "效能測試只在 EASYNOTES_E2E_PERF=1 時執行")
    }

    @MainActor
    func testLaunch() {
        let vault = TestVault()
        Fixture.standard(vault)
        addTeardownBlock { vault.cleanUp() }
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(vault: vault, sync: .off, open: nil)
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
            app.terminate()
        }
    }

    /// 4c 驗收：1,000 個元素的白板開啟時間（scripts/whiteboard-stress.py 的 E2E 版本）
    @MainActor
    func testOpenLargeWhiteboard() {
        let vault = TestVault()
        let path = "stress-1000.excalidraw"
        vault.write(Fixture.whiteboard(elements: 1000), to: path)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(path))

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options) {
            app.openDocument(path, expecting: "ink")
            app.tap(A11yID.Toolbar.back)
            app.waitFor(A11yID.List.document(path))
        }
    }

    /// 驗收情境 1 的縮小版：連續打字時記憶體與 CPU（停止輸入後應回到閒置）
    @MainActor
    func testTypingInMarkdown() {
        let vault = TestVault()
        vault.write("# 打字\n", to: "打字.md")
        let app = launch(vault, open: "打字.md")
        app.waitForEditor("markdown")
        app.typeAtEndOfNote("\n")

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            app.editorWebView.typeText(String(repeating: "lorem ipsum ", count: 20))
        }
        XCTAssertTrue(waitUntil { vault.read("打字.md")?.contains("lorem ipsum") == true })
    }

    /// 驗收情境 3：外部工具一次修改 50 個檔案，App 只處理這些路徑，列表照常更新
    @MainActor
    func testFiftyExternalChanges() {
        let vault = TestVault()
        for i in 0..<200 { vault.write("# 筆記 \(i)\n", to: "Bulk/筆記 \(i).md") }
        let app = launch(vault)
        app.tap(A11yID.Sidebar.node("Bulk"))
        app.waitFor(A11yID.List.title)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)]) {
            let stamp = UUID().uuidString.prefix(6).lowercased()
            for i in 0..<50 { vault.write("# 筆記 \(i)\n\nedit\(stamp)\n", to: "Bulk/筆記 \(i).md") }
            // 只有這個檔案有 fresh<stamp>：搜尋結果只有一筆，不會落在畫面外
            vault.write("# 新的\n\nfresh\(stamp)\n", to: "Bulk/新的 \(stamp).md")
            app.nudgeExternalScan()
            app.quickOpen("fresh\(stamp)")
            app.waitFor(A11yID.QuickOpen.hit("Bulk/新的 \(stamp).md"), timeout: 30)
            #if os(macOS)
            app.typeKey(.escape, modifierFlags: [])
            #else
            app.swipeDown()
            #endif
        }
    }
}
