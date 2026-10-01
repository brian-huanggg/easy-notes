import Foundation

/// 遠端 `files` 資料表的一列。檔案身分是 `id`，`path` 只是屬性。
public struct RemoteFile: Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var hash: String
    public var size: Int
    public var version: Int
    public var deleted: Bool
    public var deviceID: String
    public var updatedAt: Date

    public init(id: UUID, path: String, hash: String, size: Int, version: Int, deleted: Bool,
                deviceID: String, updatedAt: Date) {
        self.id = id; self.path = path; self.hash = hash; self.size = size; self.version = version
        self.deleted = deleted; self.deviceID = deviceID; self.updatedAt = updatedAt
    }
}

/// `commit_file` 的參數
public struct CommitRequest: Sendable, Equatable {
    public var id: UUID
    /// nil = 新檔案（遠端還沒有這個 id）
    public var baseVersion: Int?
    public var path: String
    public var hash: String
    public var size: Int
    public var deleted: Bool
    public var deviceID: String
}

/// 同步引擎看到的遠端。Core 不認識 Supabase；App 以 supabase-swift 實作，測試用記憶體內的假 backend。
public protocol SyncBackend: Sendable {
    /// 內容定址上傳（key = SHA-256）；同一 hash 已存在時直接成功
    func upload(_ data: Data, hash: String) async throws
    func download(hash: String) async throws -> Data
    /// 伺服器端版本檢查：`baseVersion` 等於目前版本（新檔為 nil 且 id 不存在），且沒有別的未刪除檔案佔用 `path`，
    /// 才寫入並回傳新 version；否則回傳 nil，由引擎拉取後合併。
    func commit(_ request: CommitRequest) async throws -> Int?
    /// `updatedAt` 晚於 `cursor` 的列，依 `updatedAt` 排序。可以與上次重疊，引擎會略過已套用的版本。
    func changes(since cursor: Date?) async throws -> [RemoteFile]
}
