import Foundation

/// A row of the remote `files` table. A file's identity is `id`; `path` is just an attribute.
public struct RemoteFile: Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var hash: String
    public var size: Int
    public var version: Int
    public var deleted: Bool
    /// Permanently deleted: a tombstone that only tells other devices to drop the file. Always `deleted` too; path is meaningless,
    /// hash is empty, content is gone and the file cannot be restored or committed again.
    public var purged: Bool
    public var deviceID: String
    public var updatedAt: Date

    public init(id: UUID, path: String, hash: String, size: Int, version: Int, deleted: Bool, purged: Bool = false,
                deviceID: String, updatedAt: Date) {
        self.id = id; self.path = path; self.hash = hash; self.size = size; self.version = version
        self.deleted = deleted || purged; self.purged = purged; self.deviceID = deviceID; self.updatedAt = updatedAt
    }
}

/// Parameters of `commit_file`
public struct CommitRequest: Sendable, Equatable {
    public var id: UUID
    /// nil = a new file (the remote does not have this id yet)
    public var baseVersion: Int?
    public var path: String
    public var hash: String
    public var size: Int
    public var deleted: Bool
    public var deviceID: String

    public init(id: UUID, baseVersion: Int?, path: String, hash: String, size: Int, deleted: Bool, deviceID: String) {
        self.id = id; self.baseVersion = baseVersion; self.path = path; self.hash = hash
        self.size = size; self.deleted = deleted; self.deviceID = deviceID
    }
}

/// The remote as the sync engine sees it. Core knows no Supabase; the app implements it with supabase-swift and tests use an in-memory fake backend.
public protocol SyncBackend: Sendable {
    /// Content-addressed upload (key = SHA-256); succeeds immediately when the hash already exists
    func upload(_ data: Data, hash: String) async throws
    func download(hash: String) async throws -> Data
    /// Server-side version check: writes and returns the new version only if `baseVersion` equals the current version (nil for a new file whose id does not exist)
    /// and no other undeleted file occupies `path`; otherwise returns nil and the engine pulls and merges.
    func commit(_ request: CommitRequest) async throws -> Int?
    /// Rows whose `updatedAt` is later than `cursor`, ordered by `updatedAt`. May overlap the last call; the engine skips versions already applied.
    func changes(since cursor: Date?) async throws -> [RemoteFile]
    /// Files soft-deleted after `since` and not yet purged, newest first ("Recently Deleted"); permanently deleted files are never listed
    func deletedFiles(since: Date) async throws -> [RemoteFile]
    /// Permanent delete, one atomic step for all `ids`: the rows become tombstones (`purged`), and stored content that no other file
    /// still references is deleted. Ignores versions (an explicit hard delete beats a concurrent edit); ids the server does not know or has
    /// already purged are skipped, so the call is idempotent. After it, `commit` on these ids returns nil.
    func purge(ids: [UUID], deviceID: String) async throws
}
