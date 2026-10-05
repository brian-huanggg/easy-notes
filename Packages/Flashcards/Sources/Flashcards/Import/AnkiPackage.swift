import Foundation

/// Anki 的 `.apkg` / `.colpkg`（見 architecture/flashcards.md「Anki 匯入」）：collection 與媒體檔。
/// 新格式（Anki 2.1.50 起）的 collection、media 清單與媒體檔以 zstd 壓縮；舊格式的 media 清單是 JSON
public struct AnkiPackage: Sendable {
    /// 解壓後大小的上限（不可信任的輸入）
    static let collectionLimit = 1 << 30
    static let mediaLimit = 200 << 20
    static let mediaListLimit = 64 << 20

    public let collection: AnkiCollection
    /// 媒體檔名 → zip 內的項目名稱
    let media: [String: String]
    private let archive: ZipArchive
    /// 套件的生命週期結束時刪除的暫存檔（媒體檔是在匯入時才從 zip 讀出，所以檔案要活到套件被釋放）
    private let ownedFile: OwnedFile?

    private final class OwnedFile: @unchecked Sendable {
        let url: URL
        init(_ url: URL) { self.url = url }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    public init(url: URL, deleteWhenDone: Bool = false) throws {
        let owned = deleteWhenDone ? OwnedFile(url) : nil
        ownedFile = owned
        let archive = try ZipArchive(url: url)
        self.archive = archive
        // 新格式的 collection.anki2 只是提示升級的空殼，所以先找 anki21b
        guard let name = ["collection.anki21b", "collection.anki21", "collection.anki2"] // l10n:fixed
            .first(where: { archive.entries[$0] != nil }),
            var data = try archive.data(name, limit: Self.collectionLimit)
        else { throw Failure(description: "no Anki collection in package") }
        if Zstd.isCompressed(data) { data = try Zstd.decompress(data, limit: Self.collectionLimit) }
        // Anki 的 collection 是 WAL 模式（檔頭第 18、19 byte 為 2）；唯讀開啟 WAL 的資料庫需要建立 -shm，
        // 打包後也不會有 -wal，所以改回 rollback journal（1）再開
        if data.count > 100, data[data.startIndex + 18] == 2, data[data.startIndex + 19] == 2 {
            data[data.startIndex + 18] = 1
            data[data.startIndex + 19] = 1
        }

        let temp = FileManager.default.temporaryDirectory.appending(path: "anki-\(UUID().uuidString).sqlite")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        collection = try AnkiCollection(path: temp.path(percentEncoded: false))
        media = try Self.mediaList(archive)
    }

    /// 清單中的媒體檔名：完全相同的優先；沒有時找不分大小寫且唯一的（Anki 在不分大小寫的檔案系統上，
    /// 筆記引用的大小寫可能與存檔的不同）
    func resolve(_ name: String) -> String? {
        if media[name] != nil { return name }
        let matches = media.keys.filter { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 媒體檔的內容；不在清單中或讀不到時為 nil
    func mediaData(_ name: String) throws -> Data? {
        guard let name = resolve(name), let entry = media[name],
              var data = try archive.data(entry, limit: Self.mediaLimit) else { return nil }
        if Zstd.isCompressed(data) { data = try Zstd.decompress(data, limit: Self.mediaLimit) }
        return data
    }

    var mediaNames: Set<String> { Set(media.keys) }

    /// 媒體檔名只取最後一段，空的或 `.`、`..` 不收
    static func safeMediaName(_ name: String) -> String? {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == "." || last == ".." || last.contains("\0") ? nil : last
    }

    private static func mediaList(_ archive: ZipArchive) throws -> [String: String] {
        guard var data = try archive.data("media", limit: mediaListLimit) else { return [:] } // l10n:fixed
        var result: [String: String] = [:]
        if Zstd.isCompressed(data) {
            // MediaEntries { repeated MediaEntry entries = 1 }；MediaEntry { name = 1; size = 2; sha1 = 3; legacy_zip_filename = 255 }
            data = try Zstd.decompress(data, limit: mediaListLimit)
            for (index, entry) in Protobuf.fields(data).filter({ $0.number == 1 }).enumerated() {
                guard let bytes = entry.bytes else { continue }
                let fields = Protobuf.fields(bytes)
                guard let nameData = fields.first(where: { $0.number == 1 })?.bytes,
                      let name = safeMediaName(String(decoding: nameData, as: UTF8.self)) else { continue }
                let zipName = fields.first { $0.number == 255 }?.varint.map(String.init) ?? String(index)
                result[name] = zipName
            }
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (zipName, name) in json {
                if let name = safeMediaName(name) { result[name] = zipName }
            }
        }
        return result
    }
}
