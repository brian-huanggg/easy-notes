import EasyNotesCore
import Foundation
import Supabase
import Testing
@testable import SupabaseSync

/// 對本地 Supabase 的整合測試；沒有設定環境變數時略過（用 scripts/test-sync.sh 執行）
enum Local {
    static let url = ProcessInfo.processInfo.environment["SUPABASE_TEST_URL"]
    static let key = ProcessInfo.processInfo.environment["SUPABASE_TEST_KEY"]
    static var available: Bool { url != nil && key != nil }

    static func client() -> SupabaseClient {
        SupabaseClient(supabaseURL: URL(string: url!)!, supabaseKey: key!,
                       options: .init(auth: .init(storage: InMemoryAuthStorage(), emitLocalSessionAsInitialSession: true)))
    }

    /// 本地 Supabase 不需要信箱驗證；每個測試用新帳號，互不干擾
    static func newUser() async throws -> (email: String, client: SupabaseClient) {
        let email = "test-\(UUID().uuidString.lowercased())@example.com"
        let client = client()
        try await client.auth.signUp(email: email, password: "password-123")
        return (email, client)
    }

    static func signIn(_ email: String) async throws -> SupabaseClient {
        let client = client()
        try await client.auth.signIn(email: email, password: "password-123")
        return client
    }
}

func request(_ id: UUID, base: Int?, path: String = "a.md", hash: String = "h", deleted: Bool = false) -> CommitRequest {
    CommitRequest(id: id, baseVersion: base, path: path, hash: hash, size: 1, deleted: deleted, deviceID: "test")
}

@Suite(.enabled(if: Local.available, "需要本地 Supabase：scripts/test-sync.sh"), .serialized)
struct SupabaseBackendTests {
    @Test func commitChecksVersionOnServer() async throws {
        let backend = SupabaseBackend(client: try await Local.newUser().client)
        let id = UUID()
        #expect(try await backend.commit(request(id, base: nil)) == 1)
        #expect(try await backend.commit(request(id, base: nil)) == nil)     // 已存在
        #expect(try await backend.commit(request(id, base: 1, hash: "h2")) == 2)
        #expect(try await backend.commit(request(id, base: 1, hash: "h3")) == nil) // 過期的 base
        let rows = try await backend.changes(since: nil)
        #expect(rows.count == 1)
        #expect(rows.first?.hash == "h2")
        #expect(rows.first?.version == 2)
    }

    /// 驗收：兩個 client 以同一 base version 上傳 → 一個成功、一個拿到 null
    @Test func concurrentCommitsWithSameBase() async throws {
        let (email, first) = try await Local.newUser()
        let id = UUID()
        #expect(try await SupabaseBackend(client: first).commit(request(id, base: nil)) == 1)

        for round in 0..<5 {
            let a = SupabaseBackend(client: try await Local.signIn(email))
            let b = SupabaseBackend(client: try await Local.signIn(email))
            let base = round + 1
            async let ra = a.commit(request(id, base: base, hash: "a\(round)"))
            async let rb = b.commit(request(id, base: base, hash: "b\(round)"))
            let results = try await [ra, rb]
            #expect(results.compactMap { $0 } == [base + 1], "round \(round): \(results)")
        }
    }

    @Test func pathTakenByAnotherLiveFileIsRejected() async throws {
        let backend = SupabaseBackend(client: try await Local.newUser().client)
        let a = UUID(), b = UUID()
        #expect(try await backend.commit(request(a, base: nil, path: "x.md")) == 1)
        #expect(try await backend.commit(request(b, base: nil, path: "x.md")) == nil)
        // 軟刪除後路徑可以重用
        #expect(try await backend.commit(request(a, base: 1, path: "x.md", deleted: true)) == 2)
        #expect(try await backend.commit(request(b, base: nil, path: "x.md")) == 1)
    }

    @Test func contentAddressedUploadIsIdempotent() async throws {
        let backend = SupabaseBackend(client: try await Local.newUser().client)
        let data = Data("中文內容\n".utf8)
        let hash = SyncEngine.sha256(data)
        try await backend.upload(data, hash: hash)
        try await backend.upload(data, hash: hash) // 已存在不報錯
        #expect(try await backend.download(hash: hash) == data)
    }

    @Test func deletedFilesListsSoftDeletedRows() async throws {
        let backend = SupabaseBackend(client: try await Local.newUser().client)
        let live = UUID(), gone = UUID()
        #expect(try await backend.commit(request(live, base: nil, path: "live.md")) == 1)
        #expect(try await backend.commit(request(gone, base: nil, path: "gone.md")) == 1)
        #expect(try await backend.commit(request(gone, base: 1, path: "gone.md", deleted: true)) == 2)
        let deleted = try await backend.deletedFiles(since: Date().addingTimeInterval(-86_400))
        #expect(deleted.map(\.id) == [gone])
        #expect(try await backend.deletedFiles(since: Date().addingTimeInterval(3_600)).isEmpty)
    }

    /// 驗收：用另一個帳號讀不到任何列與 Storage 物件
    @Test func rowLevelSecurityIsolatesUsers() async throws {
        let owner = SupabaseBackend(client: try await Local.newUser().client)
        let id = UUID()
        let data = Data("祕密".utf8)
        let hash = SyncEngine.sha256(data)
        try await owner.upload(data, hash: hash)
        #expect(try await owner.commit(request(id, base: nil, hash: hash)) == 1)

        let (_, otherClient) = try await Local.newUser()
        let other = SupabaseBackend(client: otherClient)
        #expect(try await other.changes(since: nil).isEmpty)
        #expect(try await other.commit(request(id, base: 1, hash: "x")) == nil) // 不能改別人的列
        #expect(try await owner.changes(since: nil).first?.version == 1)

        // 直接讀、寫對方的 Storage 路徑
        let ownerID = try await owner.client.auth.session.user.id.uuidString.lowercased()
        let bucket = otherClient.storage.from(SupabaseBackend.bucket)
        await #expect(throws: (any Error).self) { try await bucket.download(path: "\(ownerID)/\(hash)") }
        await #expect(throws: (any Error).self) {
            try await bucket.upload("\(ownerID)/evil", data: Data("x".utf8), options: FileOptions(upsert: false))
        }
        // 未登入
        let anon = Local.client()
        let rows: [[String: AnyJSON]] = try await anon.from("files").select().execute().value
        #expect(rows.isEmpty)
        await #expect(throws: (any Error).self) {
            let _: Int? = try await anon.rpc("commit_file", params: ["p_id": AnyJSON.string(UUID().uuidString)]).execute().value
        }
    }

    /// 兩台裝置透過真的 Supabase 同步：離線各改不同段落 → 內容一致
    @Test func twoDevicesConvergeThroughSupabase() async throws {
        let (email, mac) = try await Local.newUser()
        let ipad = try await Local.signIn(email)
        let userID = try await mac.auth.session.user.id.uuidString

        func device(_ name: String, _ client: SupabaseClient) throws -> (VaultFS, SyncEngine) {
            let root = FileManager.default.temporaryDirectory.appending(path: "supabase-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fs = VaultFS(root: root, kinds: try KindRegistry([]))
            return (fs, try SyncEngine(fs: fs, backend: SupabaseBackend(client: client), userID: userID, deviceName: name))
        }
        let (macFS, macEngine) = try device("Mac", mac)
        let (ipadFS, ipadEngine) = try device("iPad", ipad)

        try macFS.write(Data("一\n\n二\n".utf8), to: "筆記/a.txt")
        await macEngine.sync()
        await ipadEngine.sync()
        #expect(try ipadFS.read("筆記/a.txt") == Data("一\n\n二\n".utf8))
        #expect(await macEngine.currentStatus.lastError == nil)
        #expect(await ipadEngine.currentStatus.lastError == nil)

        try ipadFS.write(Data("一\n\n二（iPad）\n".utf8), to: "筆記/a.txt")
        await ipadEngine.sync()
        await macEngine.sync()
        #expect(try macFS.read("筆記/a.txt") == Data("一\n\n二（iPad）\n".utf8))
    }
}
