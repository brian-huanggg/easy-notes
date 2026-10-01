import Foundation

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    /// 以 `\u{1}` … `\u{2}` 標記命中文字，UI 端轉成粗體
    public let snippet: String
}

public struct TagCount: Identifiable, Hashable, Sendable {
    public var id: String { tag }
    public let tag: String
    public let count: Int
}

/// 可重建的 SQLite 索引（FTS5 trigram，中文可做子字串搜尋）。
/// 檔案才是真相：索引損毀或版本不符時直接刪掉重建。
public actor VaultIndex {
    public static let hitStart = "\u{1}"
    public static let hitEnd = "\u{2}"
    static let schemaVersion = 1

    private let fs: VaultFS
    private let db: SQLiteDB

    /// 索引位置：`<vault>/.easynotes/cache/index.sqlite`（cache 不參與同步）
    public init(fs: VaultFS, location: URL? = nil) throws {
        self.fs = fs
        let url = location ?? fs.root.appending(path: "\(VaultFS.metaFolder)/cache/index.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path(percentEncoded: false))
        try Self.migrate(db)
    }

    private static func migrate(_ db: SQLiteDB) throws {
        guard db.userVersion != schemaVersion else { return }
        try db.exec("""
            DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS links; DROP TABLE IF EXISTS tags; DROP TABLE IF EXISTS fts;
            CREATE TABLE files(path TEXT PRIMARY KEY, name TEXT NOT NULL, title TEXT NOT NULL, mtime REAL NOT NULL, size INTEGER NOT NULL);
            CREATE TABLE links(src TEXT NOT NULL, target TEXT NOT NULL);
            CREATE INDEX links_target ON links(target);
            CREATE INDEX links_src ON links(src);
            CREATE TABLE tags(path TEXT NOT NULL, tag TEXT NOT NULL);
            CREATE INDEX tags_tag ON tags(tag);
            CREATE VIRTUAL TABLE fts USING fts5(path UNINDEXED, title, body, tokenize = 'trigram');
            """)
        db.userVersion = schemaVersion
    }

    // MARK: 更新

    /// 比對磁碟與索引的 mtime/size，只重建有變動的檔案。回傳新增、修改、刪除的路徑。
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

    /// App 寫入檔案後立即更新該檔索引（不必等下一次 sync）
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
        try db.run("INSERT INTO files(path, name, title, mtime, size) VALUES(?, ?, ?, ?, ?)",
                   [.text(path), .text(name), .text(entry.title), .double(mtime), .int(size)])
        try db.run("INSERT INTO fts(path, title, body) VALUES(?, ?, ?)",
                   [.text(path), .text(entry.title), .text(entry.plainText)])
        for link in entry.links {
            try db.run("INSERT INTO links(src, target) VALUES(?, ?)", [.text(path), .text(link.lowercased())])
        }
        for tag in entry.tags {
            try db.run("INSERT INTO tags(path, tag) VALUES(?, ?)", [.text(path), .text(tag)])
        }
    }

    private func removeRows(_ path: String) throws {
        for table in ["files", "fts"] {
            try db.run("DELETE FROM \(table) WHERE path = ?", [.text(path)])
        }
        try db.run("DELETE FROM links WHERE src = ?", [.text(path)])
        try db.run("DELETE FROM tags WHERE path = ?", [.text(path)])
    }

    // MARK: 查詢

    /// `#標籤` 查標籤（含子標籤 `#a/b`）；其他為全文搜尋，空白分隔的詞以 AND 結合
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
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
        // trigram 至少要 3 個字元才能用索引；較短的詞改用 LIKE（trigram 也能加速 LIKE）
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

    /// 連到 `path` 的筆記，附上含有連結的那一行
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

    /// 連結指向 `name`（不分大小寫）的所有來源檔案
    public func sources(linkingTo name: String) throws -> [String] {
        try db.query("SELECT DISTINCT src FROM links WHERE target = ?", [.text(name.lowercased())]) { $0.text(0) }
    }

    public func tags() throws -> [TagCount] {
        try db.query("SELECT tag, COUNT(DISTINCT path) FROM tags GROUP BY tag COLLATE NOCASE ORDER BY tag COLLATE NOCASE") {
            TagCount(tag: $0.text(0), count: $0.int(1))
        }
    }

    /// `[[` 自動完成用的筆記名稱
    public func linkTargets() throws -> [String] {
        try db.query("SELECT DISTINCT name FROM files ORDER BY name COLLATE NOCASE") { $0.text(0) }
    }

    // MARK: 工具

    /// 片段只給人看：去掉 Markdown 語法，`[[目標|別名]]` 顯示別名。保留命中標記。
    static func clean(_ snippet: String) -> String {
        var s = snippet
        let rules: [(String, String)] = [
            (#"\[\[([^\]|\n]*)\|([^\]\n]*)\]\]"#, "$2"),     // [[目標|別名]] → 別名
            (#"!?\[\[|\]\]"#, ""),                            // [[ ]]
            (#"(^|\n)\s*#{1,6}\s"#, "$1"),                      // 標題
            (#"(^|\n)\s*[-*+]\s(\[[ xX]\]\s)?"#, "$1"),         // 清單、待辦
            (#"\*\*|__|~~|`"#, ""),                             // 粗體、刪除線、code
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\(hitStart)\(hitEnd)", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 取出包含 `term` 的那一行（最多約 80 字），並標記命中位置
    static func snippet(in body: String, around term: String, extendTo terminator: String? = nil) -> String {
        guard var range = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(body.prefix(80))
        }
        // 反向連結：命中範圍延伸到整個 [[…]]，別名才能被正確處理
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
