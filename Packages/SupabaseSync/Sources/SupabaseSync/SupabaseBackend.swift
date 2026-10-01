import EasyNotesCore
import Foundation
import Supabase

/// `files` 資料表 + `commit_file` RPC + Storage bucket `vault/<user_id>/<hash>`（見 supabase/migrations）
public struct SupabaseBackend: SyncBackend {
    public static let bucket = "vault"
    /// 交易可能以較早的 updated_at 較晚提交；補拉時往前多看一段，引擎會略過已套用的版本
    static let cursorOverlap: TimeInterval = 60
    static let pageSize = 500

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
                .select("id, path, hash, size, version, deleted, device_id, updated_at")
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
            .select("id, path, hash, size, version, deleted, device_id, updated_at")
            .eq("deleted", value: true)
            .gt("updated_at", value: since.formatted(.iso8601))
            .order("updated_at", ascending: false)
            .limit(Self.pageSize)
            .execute().value
        return rows.map(\.remote)
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

private struct Row: Decodable {
    let id: UUID
    let path: String
    let hash: String
    let size: Int
    let version: Int
    let deleted: Bool
    let device_id: String
    let updated_at: Date

    var remote: RemoteFile {
        RemoteFile(id: id, path: path, hash: hash, size: size, version: version, deleted: deleted,
                   deviceID: device_id, updatedAt: updated_at)
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
