import EasyNotesCore
import Foundation

/// 複習紀錄：`.easynotes/srs/<deviceId>.jsonl`，每台裝置只追加自己的檔案，同步時不會衝突。
public struct ReviewLog: Sendable {
    /// `.easynotes/` 下參與同步的子資料夾（`addSyncedMetaFolder`）
    public static let metaFolder = "srs"
    public static var folder: String { "\(VaultFS.metaFolder)/\(metaFolder)" }

    public let fs: VaultFS
    public let deviceID: String

    public init(fs: VaultFS, deviceID: String) {
        self.fs = fs
        self.deviceID = deviceID
    }

    public var path: String { "\(Self.folder)/\(deviceID).jsonl" }

    /// 追加到這台裝置的檔案。前一次寫到一半（沒有換行結尾）時先補換行，損壞的只有那一行
    public func append(_ entries: [ReviewEntry]) throws {
        guard !entries.isEmpty else { return }
        let url = fs.url(for: path)
        var text = entries.map { $0.line + "\n" }.joined()
        guard let handle = try? FileHandle(forUpdating: url) else {
            try fs.write(Data(text.utf8), to: path)
            return
        }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data("\n".utf8) { text = "\n" + text }
        }
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// 復原：檔案最後的幾行正好是 `entries` 時刪掉它們，回傳是否有刪除。
    /// 只有這台裝置會寫這個檔案，刪掉最後幾行同步出去也不會衝突
    public func removeLast(_ entries: [ReviewEntry]) throws -> Bool {
        guard !entries.isEmpty, let data = try? fs.read(path) else { return false }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= entries.count,
              zip(lines.suffix(entries.count), entries).allSatisfy({ ReviewEntry(line: $0) == $1 }) else { return false }
        lines.removeLast(entries.count)
        try fs.write(Data(lines.map { $0 + "\n" }.joined().utf8), to: path)
        return true
    }

    /// 讀取所有裝置的紀錄：卡片 id → 依 `(id, 檔名, 行)` 排序的紀錄。
    /// 略過損壞的行；同一筆（`id` + `cid` + `ease` + `op`）出現在多個檔案（例如衝突副本）只算一次
    public static func load(_ fs: VaultFS) throws -> [String: [ReviewEntry]] {
        let dir = fs.url(for: folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        struct Key: Hashable {
            var id: Int64, cid: String, ease: Int, op: ReviewEntry.Op?
        }
        var seen = Set<Key>()
        var all: [(entry: ReviewEntry, file: String, line: Int)] = []
        for url in files where url.pathExtension == "jsonl" {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for (line, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
                guard let entry = ReviewEntry(line: raw),
                      seen.insert(Key(id: entry.id, cid: entry.cid, ease: entry.ease, op: entry.op)).inserted
                else { continue }
                all.append((entry, url.lastPathComponent, line))
            }
        }
        all.sort { ($0.entry.id, $0.file, $0.line) < ($1.entry.id, $1.file, $1.line) }
        return Dictionary(grouping: all.map(\.entry), by: \.cid)
    }
}

extension Scheduler {
    /// 重播所有卡片：卡片 id → 狀態（只包含有紀錄的卡片，其餘是新卡）
    public func replay(_ history: [String: [ReviewEntry]]) -> [String: CardSchedule] {
        history.mapValues(replay)
    }
}
