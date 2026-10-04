import XCTest

/// 檔案即真相：刪掉索引（`.easynotes/cache/`）後重新啟動，列表、搜尋都從檔案重建，內容不遺失
final class IndexRebuildTests: E2ETestCase {
    @MainActor
    func testDeletingIndexRebuildsEverything() {
        let vault = TestVault()
        Fixture.standard(vault)
        var app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))
        XCTAssertTrue(waitUntil { vault.exists(".easynotes/cache/index.sqlite") }, "沒有建立索引")
        let before = vault.files()
        app.terminate()

        vault.remove(".easynotes/cache")
        app = launch(vault)

        for path in before.filter({ !$0.hasPrefix(".") }) {
            app.waitFor(A11yID.List.document(path))
        }
        app.quickOpen(Fixture.searchToken)
        app.waitFor(A11yID.QuickOpen.hit(Fixture.Path.welcome))
        XCTAssertTrue(vault.exists(".easynotes/cache/index.sqlite"), "索引沒有重建")
        // 重建索引不改動任何檔案
        XCTAssertEqual(vault.files(), before)
    }
}
