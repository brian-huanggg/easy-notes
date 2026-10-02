import Foundation
import SQLite3

/// 極簡 SQLite 包裝：只提供索引需要的功能，不引入第三方相依。
final class SQLiteDB {
    enum Value {
        case text(String)
        case double(Double)
        case int(Int)
        case null

        static func optionalText(_ s: String?) -> Value { s.map(Value.text) ?? .null }
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else { throw Error(description: "open \(path): \(String(cString: sqlite3_errmsg(handle)))") }
        try exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Error(description: "\(message) — \(sql)")
        }
    }

    func run(_ sql: String, _ args: [Value] = []) throws {
        _ = try query(sql, args) { _ in () }
    }

    /// 執行查詢；每一列交給 `row` 轉換。Statement 會被快取重用。
    func query<T>(_ sql: String, _ args: [Value] = [], row: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var results: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Error(description: "\(String(cString: sqlite3_errmsg(handle))) — \(sql)") }
            results.append(try row(Row(stmt: stmt)))
        }
        return results
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version") { $0.int(0) }.first) ?? 0 }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Error(description: "\(String(cString: sqlite3_errmsg(handle))) — \(sql)")
        }
        statements[sql] = stmt
        return stmt
    }

    struct Row {
        let stmt: OpaquePointer
        func text(_ col: Int32) -> String {
            sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
        }
        func int(_ col: Int32) -> Int {
            Int(sqlite3_column_int64(stmt, col))
        }
        func double(_ col: Int32) -> Double {
            sqlite3_column_double(stmt, col)
        }
        func isNull(_ col: Int32) -> Bool {
            sqlite3_column_type(stmt, col) == SQLITE_NULL
        }
        func optionalText(_ col: Int32) -> String? {
            isNull(col) ? nil : text(col)
        }
    }
}
