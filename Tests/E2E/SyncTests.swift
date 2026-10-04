import XCTest

/// 兩台裝置的同步 E2E：App 與測試程序（RemoteDevice）共用一個資料夾 backend（FolderSyncBackend，
/// commit 語意與 Supabase 的 `commit_file` 相同）。不需要 Docker 或網路；Supabase 本身的 RPC 與 RLS
/// 由 `scripts/test-sync.sh` 的整合測試負責。
final class SyncTests: E2ETestCase {
    /// App 閒置 3 秒才上傳，加上 Realtime（資料夾監看）與合併的時間
    static let syncTimeout: TimeInterval = 40

    @MainActor
    func testNoteCreatedInAppReachesOtherDevice() async throws {
        let (backend, remote) = try makeRemote()
        let vault = TestVault()
        vault.write("# 歡迎\n", to: Fixture.Path.welcome)
        let app = launch(vault, sync: .folder(backend))
        app.waitFor(A11yID.List.document(Fixture.Path.welcome))

        app.createNote()
        app.waitForEditor("markdown")
        let token = "sync-from-app-31"
        app.typeAtEndOfNote("\n\(token)")

        let arrived = await eventually {
            await remote.sync()
            return remote.vault.files().contains { remote.vault.read($0)?.contains(token) == true }
        }
        XCTAssertTrue(arrived, "App 新增的筆記沒有同步到另一台裝置")
        XCTAssertTrue(remote.vault.exists(Fixture.Path.welcome))
    }

    /// 另一台裝置修改開著的筆記：App 經資料夾監看（取代 Realtime）拉取，編輯器即時套用
    @MainActor
    func testRemoteEditReachesOpenEditor() async throws {
        let (backend, remote) = try makeRemote()
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault, sync: .folder(backend), open: Fixture.Path.plan)
        app.waitForEditor("markdown")

        let initial = await eventually {
            await remote.sync()
            return remote.vault.exists(Fixture.Path.plan)
        }
        XCTAssertTrue(initial, "App 沒有上傳初始檔案")

        let token = "remote-edit-55"
        remote.vault.write("# 專案計畫\n\n第一行\n\(token)\n第三行\n", to: Fixture.Path.plan)
        await remote.sync()

        XCTAssertTrue(app.editorShows(token, timeout: Self.syncTimeout), "遠端修改沒有出現在開著的編輯器")
        let saved = await eventually { vault.read(Fixture.Path.plan)?.contains(token) == true }
        XCTAssertTrue(saved, "遠端修改沒有寫進 App 的 Vault")
    }

    /// 兩邊改不同行：diff3 合併，兩台裝置最後內容相同，不產生衝突副本
    @MainActor
    func testEditsOnDifferentLinesMerge() async throws {
        let (backend, remote) = try makeRemote()
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault, sync: .folder(backend))
        app.waitFor(A11yID.List.document(Fixture.Path.plan))
        let initial = await eventually {
            await remote.sync()
            return remote.vault.exists(Fixture.Path.plan)
        }
        XCTAssertTrue(initial, "App 沒有上傳初始檔案")

        // 本機（Mac 上的 Claude Code）改第一行，另一台改第三行
        vault.write("# 專案計畫\n\n第一行 local\n第二行\n第三行\n", to: Fixture.Path.plan)
        remote.vault.write("# 專案計畫\n\n第一行\n第二行\n第三行 remote\n", to: Fixture.Path.plan)
        await remote.sync()
        app.nudgeExternalScan()

        let merged = "# 專案計畫\n\n第一行 local\n第二行\n第三行 remote\n"
        let converged = await eventually {
            await remote.sync()
            return vault.read(Fixture.Path.plan) == merged && remote.vault.read(Fixture.Path.plan) == merged
        }
        XCTAssertTrue(converged, """
            沒有合併：App「\(vault.read(Fixture.Path.plan) ?? "nil")」、另一台「\(remote.vault.read(Fixture.Path.plan) ?? "nil")」
            """)
        XCTAssertFalse(vault.files().contains { $0.contains("衝突") }, "不重疊的修改不應產生衝突副本")
    }

    /// App 內刪除 → 遠端軟刪除 → 另一台裝置的檔案也被刪除
    @MainActor
    func testDeleteInAppReachesOtherDevice() async throws {
        let (backend, remote) = try makeRemote()
        let vault = TestVault()
        Fixture.standard(vault)
        let app = launch(vault, sync: .folder(backend))
        let row = app.waitFor(A11yID.List.document(Fixture.Path.meeting))
        let initial = await eventually {
            await remote.sync()
            return remote.vault.exists(Fixture.Path.meeting)
        }
        XCTAssertTrue(initial, "App 沒有上傳初始檔案")

        app.contextMenu(on: row, select: A11yID.Menu.trash, fallbackLabel: "移到垃圾桶")

        let deleted = await eventually {
            await remote.sync()
            return !remote.vault.exists(Fixture.Path.meeting)
        }
        XCTAssertTrue(deleted, "刪除沒有同步到另一台裝置")
    }

    /// 共用的資料夾 backend 與另一台裝置；測試結束後刪除
    private func makeRemote() throws -> (URL, RemoteDevice) {
        let backend = makeBackendFolder()
        let remote = try RemoteDevice(name: "Remote", backend: backend)
        addTeardownBlock {
            remote.vault.cleanUp()
            try? FileManager.default.removeItem(at: backend)
        }
        return (backend, remote)
    }

    /// 重試 `body` 直到成立或逾時（每次之間讓出 0.5 秒）
    @MainActor
    private func eventually(timeout: TimeInterval = SyncTests.syncTimeout, _ body: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await body() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await body()
    }
}
