import Foundation

/// A file in the local sync state. `base*` is the state at the last agreement with the server and is also the three-way merge base.
struct SyncRecord: Equatable {
    var id: UUID
    /// The current local path
    var path: String
    /// The local content hash at the last scan
    var hash: String
    var mtime: Double
    var size: Int
    /// The local file no longer exists, awaiting upload of the delete
    var localDeleted = false
    /// The user chose "Delete Immediately": the remote is purged on the next upload instead of soft-deleted.
    /// Survives restarts so an offline hard delete is not downgraded to a soft one.
    var purgeRequested = false
    /// nil = never uploaded
    var baseVersion: Int?
    var baseHash: String?
    var basePath: String?

    var needsPush: Bool {
        baseVersion == nil || localDeleted || purgeRequested || hash != baseHash || path != basePath
    }
}

/// `.easynotes/sync.sqlite`: not synced; after deleting it the files match the remote by hash again on the next sync.
final class SyncState {
    static let schemaVersion = 2
    private let db: SQLiteDB
    private(set) var records: [UUID: SyncRecord] = [:]

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path(percentEncoded: false))
        if db.userVersion == 1 {
            // v1 → v2 keeps pending uploads: dropping the tables would turn a queued hard delete into a soft one
            try db.exec("ALTER TABLE files ADD COLUMN purge_requested INTEGER NOT NULL DEFAULT 0;")
            db.userVersion = Self.schemaVersion
        }
        if db.userVersion != Self.schemaVersion {
            try db.exec("""
                DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS meta;
                CREATE TABLE files(id TEXT PRIMARY KEY, path TEXT NOT NULL, hash TEXT NOT NULL, mtime REAL NOT NULL,
                  size INTEGER NOT NULL, local_deleted INTEGER NOT NULL, base_version INTEGER, base_hash TEXT, base_path TEXT,
                  purge_requested INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            db.userVersion = Self.schemaVersion
        }
        for record in try db.query("SELECT id, path, hash, mtime, size, local_deleted, base_version, base_hash, base_path, purge_requested FROM files", row: { row in
            SyncRecord(id: UUID(uuidString: row.text(0)) ?? UUID(), path: row.text(1), hash: row.text(2),
                       mtime: row.double(3), size: row.int(4), localDeleted: row.int(5) != 0,
                       purgeRequested: row.int(9) != 0,
                       baseVersion: row.isNull(6) ? nil : row.int(6),
                       baseHash: row.isNull(7) ? nil : row.text(7),
                       basePath: row.isNull(8) ? nil : row.text(8))
        }) {
            records[record.id] = record
        }
    }

    func save(_ r: SyncRecord) throws {
        records[r.id] = r
        try db.run("""
            INSERT OR REPLACE INTO files(id, path, hash, mtime, size, local_deleted, base_version, base_hash, base_path, purge_requested)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(r.id.uuidString), .text(r.path), .text(r.hash), .double(r.mtime), .int(r.size),
                  .int(r.localDeleted ? 1 : 0), r.baseVersion.map { .int($0) } ?? .null,
                  r.baseHash.map { .text($0) } ?? .null, r.basePath.map { .text($0) } ?? .null,
                  .int(r.purgeRequested ? 1 : 0)])
    }

    func remove(_ id: UUID) throws {
        records[id] = nil
        try db.run("DELETE FROM files WHERE id = ?", [.text(id.uuidString)])
    }

    func removeAll() throws {
        records = [:]
        try db.exec("DELETE FROM files; DELETE FROM meta;")
    }

    /// A file that exists locally (not deleted) at `path`
    func record(at path: String) -> SyncRecord? {
        records.values.first { $0.path == path && !$0.localDeleted }
    }

    subscript(meta key: String) -> String? {
        get { try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) }.first }
        set {
            if let newValue {
                try? db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(newValue)])
            } else {
                try? db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
            }
        }
    }
}
