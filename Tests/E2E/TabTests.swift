import XCTest

/// 分頁（Mac / iPad）：開啟檔案預設開新分頁、已開著就切過去、關閉、新分頁
final class TabTests: E2ETestCase {
    @MainActor
    func testOpeningDocumentsUsesNewTabs() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        _ = app.openDocument(Fixture.Path.plan, expecting: "markdown")
        app.waitFor(A11yID.Tabs.tab(Fixture.Path.plan))
        // 原本的列表頁留在自己的分頁
        app.tap(A11yID.Tabs.tab("all"))
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))

        // 已經開著的檔案切過去，不重複開
        app.tap(A11yID.List.document(Fixture.Path.plan))
        app.waitForEditor("markdown")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: A11yID.Tabs.tab(Fixture.Path.plan)).count, 1)
    }

    @MainActor
    func testCloseTabReturnsToNeighbour() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        _ = app.openDocument(Fixture.Path.plan, expecting: "markdown")
        app.waitFor(A11yID.Tabs.tab(Fixture.Path.plan))
        app.tap(A11yID.Tabs.close(Fixture.Path.plan))
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))
        XCTAssertTrue(waitUntil { !app.element(A11yID.Tabs.tab(Fixture.Path.plan)).exists })
    }

    @MainActor
    func testNewTabShowsAllDocuments() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        _ = app.openDocument(Fixture.Path.plan, expecting: "markdown")
        app.tap(A11yID.Tabs.new)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))
    }
}
