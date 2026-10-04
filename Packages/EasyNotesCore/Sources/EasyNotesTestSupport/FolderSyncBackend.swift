// E2E 專用：只在 DEBUG 編譯，Release 即使連結了這個 target 也不會帶進任何程式碼
#if DEBUG
import EasyNotesCore
import Foundation

/// 以一個資料夾當遠端的 `SyncBackend`：E2E 測試用，讓 App 與測試程序（另一台「裝置」）不經網路同步。
/// commit 的語意與 Supabase 的 `commit_file` RPC 相同（版本檢查、同一路徑只能有一個未刪除的檔案）。
///
/// 資料夾內容：
/// - `blobs/<hash>`：內容定址，只增不覆寫
/// - `rows.json`：`files` 資料表的所有列
/// - `lock`：跨程序的互斥鎖（`flock`），App 與測試程序同時 commit 也不會互相覆蓋
public struct FolderSyncBackend: SyncBackend {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appending(path: "blobs", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
    }

    private var rowsURL: URL { root.appending(path: "rows.json") }
    private func blobURL(_ hash: String) -> URL { root.appending(path: "blobs/\(hash)") }

    public func upload(_ data: Data, hash: String) async throws {
        let url = blobURL(hash)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try data.write(to: url, options: .atomic)
    }

    public func download(hash: String) async throws -> Data {
        try Data(contentsOf: blobURL(hash))
    }

    public func commit(_ request: CommitRequest) async throws -> Int? {
        try locked { () throws -> Int? in
            var rows = try readRows()
            let current = rows.first { $0.id == request.id }
            guard current?.version == request.baseVersion else { return nil }
            if !request.deleted,
               rows.contains(where: { $0.id != request.id && $0.path == request.path && !$0.deleted }) { return nil }
            // updatedAt 單調遞增：同一毫秒內的多次 commit 也能被 `changes(since:)` 依序取到
            let last = rows.map(\.updatedAt).max() ?? .distantPast
            let now = max(Date(), last.addingTimeInterval(0.001))
            let version = (current?.version ?? 0) + 1
            let row = RemoteFile(id: request.id, path: request.path, hash: request.hash, size: request.size,
                                 version: version, deleted: request.deleted, deviceID: request.deviceID, updatedAt: now)
            rows.removeAll { $0.id == request.id }
            rows.append(row)
            try writeRows(rows)
            return version
        }
    }

    public func changes(since cursor: Date?) async throws -> [RemoteFile] {
        try locked { try readRows() }
            .filter { $0.updatedAt > cursor ?? .distantPast }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func deletedFiles(since: Date) async throws -> [RemoteFile] {
        try locked { try readRows() }
            .filter { $0.deleted && $0.updatedAt > since }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: 儲存

    private struct Row: Codable {
        var id: UUID
        var path: String
        var hash: String
        var size: Int
        var version: Int
        var deleted: Bool
        var deviceID: String
        var updatedAt: Double

        init(_ r: RemoteFile) {
            id = r.id; path = r.path; hash = r.hash; size = r.size; version = r.version
            deleted = r.deleted; deviceID = r.deviceID; updatedAt = r.updatedAt.timeIntervalSince1970
        }

        var remote: RemoteFile {
            RemoteFile(id: id, path: path, hash: hash, size: size, version: version, deleted: deleted,
                       deviceID: deviceID, updatedAt: Date(timeIntervalSince1970: updatedAt))
        }
    }

    private func readRows() throws -> [RemoteFile] {
        guard let data = try? Data(contentsOf: rowsURL) else { return [] }
        return try JSONDecoder().decode([Row].self, from: data).map(\.remote)
    }

    private func writeRows(_ rows: [RemoteFile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows.map(Row.init)).write(to: rowsURL, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        let path = root.appending(path: "lock").path(percentEncoded: false)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: 取代 Realtime

    /// 遠端資料夾有新的 commit（`rows.json` 被替換）時呼叫 `onChange`；回傳的物件釋放時停止監看。
    /// 只在 App 前景時使用，與 Supabase Realtime 的連線時機相同。
    public static func watch(_ root: URL, onChange: @escaping @Sendable () -> Void) -> AnyObject? {
        let fd = open(root.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global())
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        return Watch(source: source)
    }

    private final class Watch {
        let source: any DispatchSourceFileSystemObject
        init(source: any DispatchSourceFileSystemObject) { self.source = source }
        deinit { source.cancel() }
    }
}

#endif
