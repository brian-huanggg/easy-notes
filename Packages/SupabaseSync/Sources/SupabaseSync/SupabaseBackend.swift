import EasyNotesCore
import Foundation
import Supabase

/// `files` 資料表 + `commit_file` RPC + Storage bucket `vault/<user_id>/<hash>`（見 supabase/migrations）
public struct SupabaseBackend: SyncBackend {
    public static let bucket = "vault"
    /// 交易可能以較早的 updated_at 較晚提交；補拉時往前多看一段，引擎會略過已套用的版本
    static let cursorOverlap: TimeInterval = 60
    static let pageSize = 500
    static let columns = "id, path, hash, size, version, deleted, purged, device_id, updated_at"

    let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func upload(_ data: Data, hash: String) async throws {
        do {
            try await client.storage.from(Self.bucket).upload(
                try await objectPath(hash), data: data,
                options: FileOptions(contentType: "application/octet-stream", upsert: false))
        } catch let error as StorageError where Self.isDuplicate(error) {
            // 內容定址：同一 hash 已上傳過
        }
    }

    public func download(hash: String) async throws -> Data {
        try await client.storage.from(Self.bucket).download(path: try await objectPath(hash))
    }

    public func commit(_ request: CommitRequest) async throws -> Int? {
        try await client.rpc("commit_file", params: CommitParams(request)).execute().value
    }

    public func changes(since cursor: Date?) async throws -> [RemoteFile] {
        var result: [RemoteFile] = []
        let after = (cursor?.addingTimeInterval(-Self.cursorOverlap) ?? .distantPast)
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        while true {
            let page: [Row] = try await client.from("files")
                .select(Self.columns)
                .gt("updated_at", value: after)
                .order("updated_at").order("id")
                .range(from: result.count, to: result.count + Self.pageSize - 1)
                .execute().value
            result += page.map(\.remote)
            if page.count < Self.pageSize { return result }
        }
    }

    public func deletedFiles(since: Date) async throws -> [RemoteFile] {
        let rows: [Row] = try await client.from("files")
            .select(Self.columns)
            .eq("deleted", value: true)
            .eq("purged", value: false)
            .gt("updated_at", value: since.formatted(.iso8601))
            .order("updated_at", ascending: false)
            .limit(Self.pageSize)
            .execute().value
        return rows.map(\.remote)
    }

    /// 一次交易把列變成墓碑，伺服器回傳「已沒有其他檔案引用」的內容 hash，再由這裡刪除那些 Storage 物件
    /// （Storage 政策只允許刪除沒被任何列引用的自己的物件，所以即使這裡送錯 hash 也刪不到仍在使用的內容）
    public func purge(ids: [UUID], deviceID: String) async throws {
        guard !ids.isEmpty else { return }
        let freed: [String] = try await client.rpc("purge_files", params: PurgeParams(p_ids: ids, p_device: deviceID))
            .execute().value
        guard !freed.isEmpty else { return }
        let prefix = try await client.auth.session.user.id.uuidString.lowercased()
        // 列已是墓碑，內容刪除失敗也不能回頭：沒有被引用的孤兒內容只佔空間，不會被讀到
        _ = try? await client.storage.from(Self.bucket).remove(paths: freed.map { "\(prefix)/\($0)" })
    }

    /// Storage 政策比對 `auth.uid()::text`，是小寫的 uuid
    private func objectPath(_ hash: String) async throws -> String {
        "\(try await client.auth.session.user.id.uuidString.lowercased())/\(hash)"
    }

    static func isDuplicate(_ error: StorageError) -> Bool {
        error.statusCode == "409" || error.error == "Duplicate" || error.message.localizedCaseInsensitiveContains("already exists")
    }
}

private struct CommitParams: Encodable {
    let p_id: UUID
    let p_base_version: Int?
    let p_path: String
    let p_hash: String
    let p_size: Int
    let p_deleted: Bool
    let p_device: String

    init(_ r: CommitRequest) {
        p_id = r.id; p_base_version = r.baseVersion; p_path = r.path; p_hash = r.hash
        p_size = r.size; p_deleted = r.deleted; p_device = r.deviceID
    }

    // nil 要送出 null，而不是省略參數（RPC 依參數名稱比對函式簽章）
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_id, forKey: .p_id)
        try c.encode(p_base_version, forKey: .p_base_version)
        try c.encode(p_path, forKey: .p_path)
        try c.encode(p_hash, forKey: .p_hash)
        try c.encode(p_size, forKey: .p_size)
        try c.encode(p_deleted, forKey: .p_deleted)
        try c.encode(p_device, forKey: .p_device)
    }

    enum CodingKeys: CodingKey { case p_id, p_base_version, p_path, p_hash, p_size, p_deleted, p_device }
}

private struct PurgeParams: Encodable {
    let p_ids: [UUID]
    let p_device: String
}

private struct Row: Decodable {
    let id: UUID
    let path: String
    let hash: String
    let size: Int
    let version: Int
    let deleted: Bool
    let purged: Bool
    let device_id: String
    let updated_at: Date

    var remote: RemoteFile {
        RemoteFile(id: id, path: path, hash: hash, size: size, version: version, deleted: deleted,
                   purged: purged, deviceID: device_id, updatedAt: updated_at)
    }
}

/// 只放在記憶體的登入狀態（測試用；App 用預設的 Keychain）
public final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func store(key: String, value: Data) throws { lock.withLock { items[key] = value } }
    public func retrieve(key: String) throws -> Data? { lock.withLock { items[key] } }
    public func remove(key: String) throws { _ = lock.withLock { items.removeValue(forKey: key) } }
}
