import XCTest

/// 在 App 內新增、編輯、改名、搬移、釘選、刪除：每個操作都以磁碟上的檔案驗證
final class DocumentLifecycleTests: E2ETestCase {
    @MainActor
    func testNewNoteIsWrittenAndTypingIsSaved() {
        let vault = TestVault()
        vault.write("# 歡迎\n", to: Fixture.Path.welcome)
        let app = launch(vault)
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))
        let before = vault.files()

        app.createNote()
        var created: String?
        XCTAssertTrue(waitUntil {
            created = vault.files().subtracting(before).first { $0.hasSuffix(".md") }
            return created != nil
        }, "新增筆記沒有在 Vault 建立 .md")
        app.waitForEditor("markdown")

        // WebView 編輯器 → Bridge（停止輸入 300ms）→ VaultStore → 磁碟
        let token = "E2E bridge 42"
        app.typeAtEndOfNote("\n\(token)")
        XCTAssertTrue(waitUntil { vault.read(created!)?.contains(token) == true }, "打的字沒有存進 \(created!)")
    }

    @MainActor
    func testRenameRewritesLinksInOtherNotes() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        let row = app.waitFor(A11yID.List.document(Fixture.Path.plan))

        app.contextMenu(on: row, select: A11yID.Menu.rename, fallbackLabel: "重新命名")
        app.confirmRename("Plan B")

        XCTAssertTrue(waitUntil { vault.exists("Projects/Plan B.md") && !vault.exists(Fixture.Path.plan) },
                      "檔案沒有改名")
        // 指向它的 [[連結]] 一併更新
        XCTAssertTrue(waitUntil {
            vault.read(Fixture.Path.welcome)?.contains("[[Plan B]]") == true
                && vault.read(Fixture.Path.meeting)?.contains("[[Plan B]]") == true
        }, "其他筆記的連結沒有更新")
        app.waitFor(A11yID.List.document("Projects/Plan B.md"))
    }

    @MainActor
    func testPinIsStoredInFrontmatter() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        let row = app.waitFor(A11yID.List.document(Fixture.Path.welcome))

        app.contextMenu(on: row, select: A11yID.Menu.pin, fallbackLabel: "釘選")

        XCTAssertTrue(waitUntil { vault.read(Fixture.Path.welcome)?.contains("pinned: true") == true },
                      "釘選沒有寫進 frontmatter")
        app.waitFor(A11yID.Sidebar.pinned).tapOrClick()
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))
    }

    @MainActor
    func testDeleteRemovesFile() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)
        let row = app.waitFor(A11yID.List.document(Fixture.Path.budget))

        app.contextMenu(on: row, select: A11yID.Menu.trash, fallbackLabel: "移到垃圾桶")

        XCTAssertTrue(waitUntil { !vault.exists(Fixture.Path.budget) }, "檔案沒有被刪除")
        XCTAssertTrue(waitUntil { !app.element(A11yID.List.document(Fixture.Path.budget)).exists }, "列表還顯示已刪除的檔案")
    }

    /// 側邊欄拖曳：把檔案拖到另一個空間 = 搬進該資料夾，檔名不變
    @MainActor
    func testDragFileToAnotherSpaceMovesIt() {
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault)

        // 點空間 = 開啟並展開，檔案才會出現在側邊欄
        app.tap(A11yID.Sidebar.node("Projects"))
        let source = app.waitFor(A11yID.Sidebar.node(Fixture.Path.meeting))
        let target = app.waitFor(A11yID.Sidebar.node("Study"))
        #if os(macOS)
        source.click(forDuration: 0.6, thenDragTo: target)
        #else
        source.press(forDuration: 1.0, thenDragTo: target)
        #endif

        XCTAssertTrue(waitUntil { vault.exists("Study/會議記錄.md") && !vault.exists(Fixture.Path.meeting) },
                      "拖曳沒有搬移檔案")
        // 檔名不變，所以連結不必改寫
        XCTAssertEqual(vault.read("Study/會議記錄.md"), "# 會議記錄\n\n- 決議：見 [[專案計畫]]\n")
    }
}
