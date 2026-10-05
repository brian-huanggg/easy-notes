import Foundation

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    /// Marks matched text with `\u{1}` … `\u{2}`, which the UI turns into bold
    public let snippet: String

    public init(path: String, title: String, snippet: String) {
        self.path = path
        self.title = title
        self.snippet = snippet
    }
}

/// A file in the index (used by list pages and sidebar counts)
public struct IndexedFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let mtime: Date
    public var icon: String? = nil
    public var pinned = false
    public var summary: String? = nil
    /// SHA-256 of the content; the preview cache key
    public var hash = ""
}

public struct TagCount: Identifiable, Hashable, Sendable {
    public var id: String { tag }
    public let tag: String
    public let count: Int
}

/// A rebuildable SQLite index (FTS5 trigram, so Chinese supports substring search).
/// Files are the truth: a corrupted or version-mismatched index is simply deleted and rebuilt.
public actor VaultIndex {
    public static let hitStart = "\u{1}"
    public static let hitEnd = "\u{2}"
    static let schemaVersion = 3

    private let fs: VaultFS
    private let db: SQLiteDB
    private let contributors: [any IndexContributor]

    /// Index location: `<vault>/.easynotes/cache/index.sqlite` (cache does not take part in sync)
    /// `language`: the UI language when display text (`summary`) was produced; Core only compares it and never interprets it, and a difference from last time rebuilds the whole index
    public init(fs: VaultFS, location: URL? = nil, contributors: [any IndexContributor] = [], language: String = "") throws {
        self.fs = fs
        self.contributors = contributors
        let url = location ?? fs.root.appending(path: "\(VaultFS.metaFolder)/cache/index.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path(percentEncoded: false))
        try Self.migrate(db)
        try Self.resetIfContributorsChanged(db, contributors, language: language)
    }

    private static func migrate(_ db: SQLiteDB) throws {
        guard db.userVersion != schemaVersion else { return }
        try db.exec("""
            DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS links; DROP TABLE IF EXISTS tags; DROP TABLE IF EXISTS fts;
            CREATE TABLE files(path TEXT PRIMARY KEY, name TEXT NOT NULL, title TEXT NOT NULL, mtime REAL NOT NULL, size INTEGER NOT NULL,
                icon TEXT, pinned INTEGER NOT NULL DEFAULT 0, summary TEXT, hash TEXT NOT NULL DEFAULT '');
            CREATE TABLE links(src TEXT NOT NULL, target TEXT NOT NULL);
            CREATE INDEX links_target ON links(target);
            CREATE INDEX links_src ON links(src);
            CREATE TABLE tags(path TEXT NOT NULL, tag TEXT NOT NULL);
            CREATE INDEX tags_tag ON tags(tag);
            CREATE VIRTUAL TABLE fts USING fts5(path UNINDEXED, title, body, tokenize = 'trigram');
            DROP TABLE IF EXISTS records; DROP TABLE IF EXISTS meta;
            CREATE TABLE records(contributor TEXT NOT NULL, path TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL);
            CREATE INDEX records_path ON records(path);
            CREATE INDEX records_key ON records(contributor, key);
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        db.userVersion = schemaVersion
    }

    /// Clears the index when plugin extraction rules change (a contributor added, removed or its version changed) or the display-text language changes; the next sync rebuilds everything
    private static func resetIfContributorsChanged(_ db: SQLiteDB, _ contributors: [any IndexContributor], language: String) throws {
        let signature = contributors.map { "\($0.id):\($0.version)" }.sorted().joined(separator: ",") + "|\(language)"
        let stored = try db.query("SELECT value FROM meta WHERE key = 'contributors'") { $0.text(0) }.first
        guard stored != signature else { return }
        try db.transaction {
            for table in ["files", "fts", "links", "tags", "records"] { try db.run("DELETE FROM \(table)") }
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('contributors', ?)", [.text(signature)])
        }
    }

    // MARK: Updating

    /// Compares disk mtime/size with the index and rebuilds only changed files. Returns the added, modified and deleted paths.
    @discardableResult
    public func sync() throws -> Set<String> {
        let onDisk = Dictionary(uniqueKeysWithValues: try fs.fileStats().map { ($0.path, $0) })
        let indexed = Dictionary(uniqueKeysWithValues: try db.query("SELECT path, mtime, size FROM files") {
            ($0.text(0), (mtime: $0.double(1), size: $0.int(2)))
        })
        var changed = Set<String>()
        try db.transaction {
            for (path, stat) in onDisk {
                if let old = indexed[path], old.mtime == stat.mtime, old.size == stat.size { continue }
                try indexFile(path, data: try fs.read(path), mtime: stat.mtime, size: stat.size)
                changed.insert(path)
            }
            for path in indexed.keys where onDisk[path] == nil {
                try removeRows(path)
                changed.insert(path)
            }
        }
        return changed
    }

    /// Rescans only the paths an event carries (FSEvents, sync). A folder expands to the files under it; a nonexistent path is removed along with the index entries below it.
    /// Returns the added, modified and deleted file paths.
    @discardableResult
    public func sync(paths: Set<String>) throws -> Set<String> {
        var targets = Set<String>()
        for path in paths where !path.isEmpty {
            targets.formUnion(try db.query("SELECT path FROM files WHERE path = ? OR path LIKE ? ESCAPE '\\'",
                                           [.text(path), .text(Self.likePrefix(path))]) { $0.text(0) })
            var isDir: ObjCBool = false
            let url = fs.url(for: path)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let child = walker?.nextObject() as? URL { targets.insert(fs.path(for: child)) }
            } else {
                targets.insert(path)
            }
        }
        var changed = Set<String>()
        try db.transaction {
            for path in targets {
                let old = try db.query("SELECT mtime, size FROM files WHERE path = ?", [.text(path)]) {
                    (mtime: $0.double(0), size: $0.int(1))
                }.first
                guard fs.kinds.kind(for: path) != nil, let stat = try? fs.fileStat(path) else {
                    if old != nil {
                        try removeRows(path)
                        changed.insert(path)
                    }
                    continue
                }
                if let old, old.mtime == stat.mtime, old.size == stat.size { continue }
                try indexFile(path, data: try fs.read(path), mtime: stat.mtime, size: stat.size)
                changed.insert(path)
            }
        }
        return changed
    }

    private static func likePrefix(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "/%"
    }

    /// Updates a file's index right after the app writes it (no need to wait for the next sync)
    public func update(_ path: String, data: Data) throws {
        let stat = try fs.fileStat(path)
        try db.transaction {
            try indexFile(path, data: data, mtime: stat?.mtime ?? 0, size: stat?.size ?? data.count)
        }
    }

    public func remove(_ path: String) throws {
        try db.transaction { try removeRows(path) }
    }

    private func indexFile(_ path: String, data: Data, mtime: Double, size: Int) throws {
        try removeRows(path)
        let url = fs.url(for: path)
        guard let kind = fs.kinds.kind(for: url) else { return }
        let entry = kind.index(data, fileName: url.lastPathComponent)
        let name = fs.kinds.displayName(path)
        try db.run("INSERT INTO files(path, name, title, mtime, size, icon, pinned, summary, hash) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   [.text(path), .text(name), .text(entry.title), .double(mtime), .int(size), .optionalText(entry.icon),
                    .int(entry.pinned ? 1 : 0), .optionalText(entry.summary), .text(SyncEngine.sha256(data))])
        try db.run("INSERT INTO fts(path, title, body) VALUES(?, ?, ?)",
                   [.text(path), .text(entry.title), .text(entry.plainText)])
        for link in entry.links {
            try db.run("INSERT INTO links(src, target) VALUES(?, ?)", [.text(path), .text(link.lowercased())])
        }
        for tag in entry.tags {
            try db.run("INSERT INTO tags(path, tag) VALUES(?, ?)", [.text(path), .text(tag)])
        }
        for contributor in contributors {
            for record in contributor.records(path: path, kindID: kind.id, data: data) {
                try db.run("INSERT INTO records(contributor, path, key, value) VALUES(?, ?, ?, ?)",
                           [.text(contributor.id), .text(path), .text(record.key), .text(record.value)])
            }
        }
    }

    private func removeRows(_ path: String) throws {
        for table in ["files", "fts"] {
            try db.run("DELETE FROM \(table) WHERE path = ?", [.text(path)])
        }
        try db.run("DELETE FROM links WHERE src = ?", [.text(path)])
        try db.run("DELETE FROM tags WHERE path = ?", [.text(path)])
        try db.run("DELETE FROM records WHERE path = ?", [.text(path)])
    }

    // MARK: Queries

    /// `#tag` queries tags (including subtags `#a/b`); anything else is full-text search, with space-separated terms combined by AND
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        try searchAll(query, limit: limit).filter { !fs.kinds.isCompanion($0.path) }
    }

    private func searchAll(_ query: String, limit: Int) throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        if q.hasPrefix("#"), !q.contains(" ") {
            let tag = String(q.dropFirst())
            return try db.query("""
                SELECT DISTINCT f.path, f.title FROM tags t JOIN files f ON f.path = t.path
                WHERE t.tag = ? COLLATE NOCASE OR t.tag LIKE ? ORDER BY f.title LIMIT ?
                """, [.text(tag), .text(tag + "/%"), .int(limit)]) {
                SearchHit(path: $0.text(0), title: $0.text(1), snippet: "")
            }
        }

        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        // trigram needs at least 3 characters to use the index; shorter terms use LIKE (trigram can also speed up LIKE)
        if terms.allSatisfy({ $0.count >= 3 }) {
            let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
            return try db.query("""
                SELECT path, title, snippet(fts, 2, char(1), char(2), '…', 16) FROM fts
                WHERE fts MATCH ? ORDER BY bm25(fts, 0, 5, 1) LIMIT ?
                """, [.text(match), .int(limit)]) {
                SearchHit(path: $0.text(0), title: $0.text(1), snippet: Self.clean($0.text(2)))
            }
        }

        let clause = terms.map { _ in "(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        let args = terms.flatMap { t -> [SQLiteDB.Value] in
            let pattern = "%\(t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
            return [.text(pattern), .text(pattern)]
        }
        return try db.query("SELECT path, title, body FROM fts WHERE \(clause) LIMIT ?", args + [.int(limit)]) {
            SearchHit(path: $0.text(0), title: $0.text(1), snippet: Self.clean(Self.snippet(in: $0.text(2), around: terms[0])))
        }
    }

    /// Notes linking to `path`, with the line containing the link
    public func backlinks(to path: String) throws -> [SearchHit] {
        let name = fs.kinds.displayName(path)
        return try db.query("""
            SELECT DISTINCT l.src, f.title, x.body FROM links l
            JOIN files f ON f.path = l.src JOIN fts x ON x.path = l.src
            WHERE l.target = ? AND l.src != ? ORDER BY f.title
            """, [.text(name.lowercased()), .text(path)]) {
            SearchHit(path: $0.text(0), title: $0.text(1), snippet: Self.clean(Self.snippet(in: $0.text(2), around: "[[" + name, extendTo: "]]")))
        }
    }

    /// All source files whose links point at `name` (case-insensitive)
    public func sources(linkingTo name: String) throws -> [String] {
        try db.query("SELECT DISTINCT src FROM links WHERE target = ?", [.text(name.lowercased())]) { $0.text(0) }
    }

    public func tags() throws -> [TagCount] {
        try db.query("SELECT tag, COUNT(DISTINCT path) FROM tags GROUP BY tag COLLATE NOCASE ORDER BY tag COLLATE NOCASE") {
            TagCount(tag: $0.text(0), count: $0.int(1))
        }
    }

    /// Path → that file's tags (sorted by tag name; files without tags are not listed)
    public func fileTags() throws -> [String: [String]] {
        let rows = try db.query("SELECT path, tag FROM tags ORDER BY path, tag COLLATE NOCASE") { ($0.text(0), $0.text(1)) }
        return rows.reduce(into: [:]) { result, row in
            if result[row.0]?.contains(row.1) != true { result[row.0, default: []].append(row.1) }
        }
    }

    /// All indexed files, most recently modified first; companions are not listed
    public func files() throws -> [IndexedFile] {
        try db.query("SELECT \(Self.fileColumns("")) FROM files ORDER BY mtime DESC", row: Self.indexedFile)
            .filter { !fs.kinds.isCompanion($0.path) }
    }

    /// Files with tag `tag` (including subtags `tag/…`), most recently modified first
    public func files(taggedWith tag: String) throws -> [IndexedFile] {
        try db.query("""
            SELECT DISTINCT \(Self.fileColumns("f.")) FROM tags t JOIN files f ON f.path = t.path
            WHERE t.tag = ? COLLATE NOCASE OR t.tag LIKE ? ORDER BY f.mtime DESC
            """, [.text(tag), .text(tag + "/%")], row: Self.indexedFile)
            .filter { !fs.kinds.isCompanion($0.path) }
    }

    private static func fileColumns(_ table: String) -> String {
        ["path", "title", "mtime", "icon", "pinned", "summary", "hash"].map { table + $0 }.joined(separator: ", ")
    }

    private static func indexedFile(_ row: SQLiteDB.Row) -> IndexedFile {
        IndexedFile(path: row.text(0), title: row.text(1), mtime: Date(timeIntervalSince1970: row.double(2)),
                    icon: row.optionalText(3), pinned: row.int(4) != 0, summary: row.optionalText(5), hash: row.text(6))
    }

    /// All records of a contributor, sorted by path
    public func records(_ contributor: String) throws -> [(path: String, record: IndexRecord)] {
        try db.query("SELECT path, key, value FROM records WHERE contributor = ? ORDER BY path, rowid",
                     [.text(contributor)]) { ($0.text(0), IndexRecord(key: $0.text(1), value: $0.text(2))) }
    }

    /// Which files a key appears in (for example whether a card id is already used by another file)
    public func paths(withKey key: String, contributor: String) throws -> [String] {
        try db.query("SELECT DISTINCT path FROM records WHERE contributor = ? AND key = ? ORDER BY path",
                     [.text(contributor), .text(key)]) { $0.text(0) }
    }

    /// Note names for `[[` autocomplete
    public func linkTargets() throws -> [String] {
        try db.query("SELECT DISTINCT name FROM files ORDER BY name COLLATE NOCASE") { $0.text(0) }
    }

    // MARK: Utilities

    /// The snippet is for humans only: Markdown syntax removed, `[[target|alias]]` shows the alias. Match markers are kept.
    static func clean(_ snippet: String) -> String {
        var s = snippet
        let rules: [(String, String)] = [
            (#"\[\[([^\[\]|\n]*)\|([^\[\]\n]*)\]\]"#, "$2"),     // [[target|alias]] → alias
            (#"!?\[\[|\]\]"#, ""),                            // [[ ]]
            (#"(^|\n)\s*#{1,6}\s"#, "$1"),                      // Headings
            (#"(^|\n)\s*[-*+]\s(\[[ xX]\]\s)?"#, "$1"),         // Lists, tasks
            (#"\*\*|__|~~|`"#, ""),                             // Bold, strikethrough, code
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\(hitStart)\(hitEnd)", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Takes the line containing `term` (at most about 80 characters) and marks the match position
    static func snippet(in body: String, around term: String, extendTo terminator: String? = nil) -> String {
        guard var range = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(body.prefix(80))
        }
        // Backlinks: the match range extends to the whole [[…]], so aliases are handled correctly
        if let terminator, let end = body.range(of: terminator, range: range.upperBound..<body.endIndex) {
            range = range.lowerBound..<end.upperBound
        }
        let lineStart = body[..<range.lowerBound].lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
        let lineEnd = body[range.upperBound...].firstIndex(of: "\n") ?? body.endIndex
        let before = body[lineStart..<range.lowerBound].suffix(40)
        let after = body[range.upperBound..<lineEnd].prefix(40)
        return (before.startIndex > lineStart ? "…" : "") + before + hitStart + body[range] + hitEnd + after
            + (after.endIndex < lineEnd ? "…" : "")
    }
}
