import XCTest

/// 開啟 Vault：檔案樹、列表都來自磁碟上的檔案
final class LaunchTests: E2ETestCase {
    @MainActor
    func testShowsSpacesAndEveryDocument() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        // 空間 = 第一層資料夾
        app.waitFor(A11yID.Sidebar.node("Projects"))
        app.waitFor(A11yID.Sidebar.node("Study"))
        // 所有文件：每種外掛的檔案都在
        for path in [Fixture.Path.welcome, Fixture.Path.plan, Fixture.Path.meeting, Fixture.Path.board,
                     Fixture.Path.budget, Fixture.Path.handout, Fixture.Path.cards, Fixture.Path.guide] {
            app.waitFor(A11yID.List.document(path))
        }
        // 已有 seeded 標記：不產生範例檔；Vault 的 CLAUDE.md 已存在就不改寫
        XCTAssertEqual(vault.files().count, Fixture.standardDocumentCount)
        XCTAssertEqual(vault.read(Fixture.Path.guide), "# EasyNotes Vault\n")
    }

    @MainActor
    func testWritesVaultGuideWhenMissing() {
        let vault = TestVault()
        vault.write("# 筆記\n", to: "筆記.md")
        let app = launch(vault)
        app.waitFor(A11yID.List.document("筆記.md"))
        XCTAssertTrue(waitUntil { vault.read("CLAUDE.md")?.contains("# EasyNotes Vault") == true },
                      "App 沒有建立 Vault 的 CLAUDE.md")
    }
}
