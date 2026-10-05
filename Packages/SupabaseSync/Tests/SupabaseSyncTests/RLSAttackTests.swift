import EasyNotesCore
import Foundation
import Supabase
import Testing
@testable import SupabaseSync

/// 直接對 PostgREST / Storage 發動越權操作（不經 commit_file、不經 SyncEngine），驗證 security.md「同步」的防護。
/// 需要本地 Supabase：scripts/test-sync.sh
@Suite(.enabled(if: Local.available, "需要本地 Supabase：scripts/test-sync.sh"), .serialized)
struct RLSAttackTests {
    private func userID(_ client: SupabaseClient) async throws -> String {
        try await client.auth.session.user.id.uuidString.lowercased()
    }

    private func insertRow(user: String, path: String = "x.md") -> [String: AnyJSON] {
        ["id": .string(UUID().uuidString), "user_id": .string(user), "path": .string(path), "hash": "h",
         "size": 1, "version": 1, "deleted": false, "device_id": "evil"]
    }

    /// `files` 沒有 insert / update / delete 政策：登入的使用者也不能繞過 commit_file 直接寫
    @Test func directTableWritesAreDenied() async throws {
        let (_, attacker) = try await Local.newUser()
        let me = try await userID(attacker)

        await #expect(throws: (any Error).self) { try await attacker.from("files").insert(insertRow(user: me)).execute() }

        // 受害者有一列；攻擊者的 update / delete 都不能影響它
        let (_, victim) = try await Local.newUser()
        let victimID = try await userID(victim)
        let id = UUID()
        let backend = SupabaseBackend(client: victim)
        #expect(try await backend.commit(request(id, base: nil, hash: "orig")) == 1)

        await #expect(throws: (any Error).self) {
            try await attacker.from("files").insert(insertRow(user: victimID)).execute()   // 假冒別人的 user_id
        }
        _ = try? await attacker.from("files").update(["hash": AnyJSON.string("pwn")]).eq("id", value: id.uuidString).execute()
        _ = try? await attacker.from("files").delete().eq("id", value: id.uuidString).execute()
        // 自己對自己的列也一樣
        let mine = UUID()
        #expect(try await SupabaseBackend(client: attacker).commit(request(mine, base: nil, hash: "mine")) == 1)
        _ = try? await attacker.from("files").update(["hash": AnyJSON.string("pwn")]).eq("id", value: mine.uuidString).execute()
        _ = try? await attacker.from("files").delete().eq("id", value: mine.uuidString).execute()

        let rows = try await backend.changes(since: nil)
        #expect(rows.count == 1 && rows[0].hash == "orig" && rows[0].version == 1)
        let own = try await SupabaseBackend(client: attacker).changes(since: nil)
        #expect(own.count == 1 && own[0].hash == "mine" && own[0].version == 1)
    }

    /// 只增不覆寫：自己上傳的 blob 也不能被 upsert 覆寫或刪除
    @Test func ownBlobsCannotBeOverwrittenOrDeleted() async throws {
        let (_, client) = try await Local.newUser()
        let backend = SupabaseBackend(client: client)
        let data = Data("原文".utf8)
        let hash = SyncEngine.sha256(data)
        try await backend.upload(data, hash: hash)

        let bucket = client.storage.from(SupabaseBackend.bucket)
        let path = "\(try await userID(client))/\(hash)"
        _ = try? await bucket.upload(path, data: Data("被覆寫".utf8), options: FileOptions(upsert: true))
        _ = try? await bucket.remove(paths: [path])
        #expect(try await backend.download(hash: hash) == data)
    }

    /// 上傳路徑的第一段是自己的 id，但後面用 `..` 繞到別人的資料夾
    @Test func storagePathTraversalIntoOtherFolderIsDenied() async throws {
        let (_, victim) = try await Local.newUser()
        let victimID = try await userID(victim)
        let (_, attacker) = try await Local.newUser()
        let me = try await userID(attacker)
        let bucket = attacker.storage.from(SupabaseBackend.bucket)

        for path in ["\(me)/../\(victimID)/evil", "\(me)/%2e%2e/\(victimID)/evil", "\(victimID)/evil", "evil", "/\(victimID)/evil"] {
            _ = try? await bucket.upload(path, data: Data("x".utf8), options: FileOptions(upsert: false))
        }
        // 受害者的資料夾沒有出現任何東西
        let listed = try await victim.storage.from(SupabaseBackend.bucket).list(path: victimID)
        #expect(listed.isEmpty, "victim folder: \(listed.map(\.name))")
        // 攻擊者也列不到別人的資料夾
        let seen = (try? await bucket.list(path: victimID)) ?? []
        #expect(seen.isEmpty)
    }

    /// 未登入：列不出、下載不到（bucket 是私有的）
    @Test func anonymousCannotReadStorage() async throws {
        let (_, owner) = try await Local.newUser()
        let backend = SupabaseBackend(client: owner)
        let data = Data("祕密".utf8)
        let hash = SyncEngine.sha256(data)
        try await backend.upload(data, hash: hash)
        let ownerID = try await userID(owner)

        let anon = Local.client().storage.from(SupabaseBackend.bucket)
        await #expect(throws: (any Error).self) { try await anon.download(path: "\(ownerID)/\(hash)") }
        #expect(((try? await anon.list(path: ownerID)) ?? []).isEmpty)
        // 公開網址也不能讀
        let publicURL = try anon.getPublicURL(path: "\(ownerID)/\(hash)")
        let (body, response) = try await URLSession.shared.data(from: publicURL)
        #expect((response as? HTTPURLResponse)?.statusCode != 200, "public URL leaked \(body.count) bytes")
    }

    /// 內部維護函式（purge）與 commit_file 的權限：只有 commit_file 對 authenticated 開放
    @Test func maintenanceFunctionsAreNotCallable() async throws {
        let (_, client) = try await Local.newUser()
        await #expect(throws: (any Error).self) {
            let _: Int = try await client.rpc("purge_deleted_files").execute().value
        }
        let anon = Local.client()
        await #expect(throws: (any Error).self) {
            let _: Int = try await anon.rpc("purge_deleted_files").execute().value
        }
    }

    /// 客戶端送來的 user_id 不被採用：commit_file 一律用 auth.uid()
    @Test func commitFileOwnsRowsByAuthUid() async throws {
        let (_, a) = try await Local.newUser()
        let (_, b) = try await Local.newUser()
        let id = UUID()
        #expect(try await SupabaseBackend(client: a).commit(request(id, base: nil)) == 1)
        let rows: [[String: AnyJSON]] = try await a.from("files").select("user_id").eq("id", value: id.uuidString).execute().value
        #expect(rows.first?["user_id"]?.stringValue == (try await userID(a)))
        // 同一個 id：另一個使用者既不能覆寫、也不能軟刪除
        #expect(try await SupabaseBackend(client: b).commit(request(id, base: 1, hash: "x")) == nil)
        #expect(try await SupabaseBackend(client: b).commit(request(id, base: 1, deleted: true)) == nil)
        #expect(try await SupabaseBackend(client: a).changes(since: nil).first?.deleted == false)
    }
}
