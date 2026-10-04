import XCTest

/// ⌘K 快速開啟（FTS5 搜尋）、[[連結]]、上一頁 / 下一頁
final class NavigationTests: E2ETestCase {
    @MainActor
    func testQuickOpenFindsContentAndOpensIt() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))

        app.quickOpen(Fixture.searchToken)
        app.tap(A11yID.QuickOpen.hit(Fixture.Path.welcome))

        app.waitForEditor("markdown")
        XCTAssertTrue(app.editorShows(Fixture.searchToken))
    }

    @MainActor
    func testBackAndForward() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        // 資料夾、列表留在目前分頁，歷史照常（檔案則開在新分頁，見 TabTests）
        app.waitFor(A11yID.List.document(Fixture.Path.plan))
        app.tap(A11yID.Sidebar.node("Study"))
        app.waitFor(A11yID.List.document(Fixture.Path.cards))
        app.tap(A11yID.Toolbar.back)
        app.waitFor(A11yID.List.document(Fixture.Path.plan))
        app.tap(A11yID.Toolbar.forward)
        app.waitFor(A11yID.List.document(Fixture.Path.cards))
    }

    @MainActor
    func testFolderPageListsOnlyItsDocuments() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        app.tap(A11yID.Sidebar.node("Study"))
        app.waitFor(A11yID.List.document(Fixture.Path.cards))
        app.waitFor(A11yID.List.document(Fixture.Path.handout))
        XCTAssertFalse(app.element(A11yID.List.document(Fixture.Path.plan)).exists)
    }

    @MainActor
    func testKindFilter() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))

        app.tap(A11yID.List.filter("csv"))
        app.waitFor(A11yID.List.document(Fixture.Path.budget))
        XCTAssertTrue(waitUntil { !app.element(A11yID.List.document(Fixture.Path.welcome)).exists })
        app.tap(A11yID.List.filterAll)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))
    }
}
