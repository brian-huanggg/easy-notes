import EasyNotesCore
import Foundation

/// 卡片寫在 Markdown 裡。Flashcards 不 import Markdown 外掛，只以 kind id 辨識。
let markdownKindID = "markdown"

/// 從 md 抽出卡片存進索引：每筆 note 一筆 record，key = note id，value = `CardNote` 的 JSON。
/// 還沒有 id 的卡片不進索引（`CardIDFixer` 補上後會重新索引）。
public struct CardIndexer: IndexContributor {
    public static let contributorID = "cards"
    public let id = CardIndexer.contributorID
    public let version = 2

    public init() {}

    public func records(path: String, kindID: String, data: Data) -> [IndexRecord] {
        guard kindID == markdownKindID else { return [] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var seen = Set<String>()
        return CardSyntax.parse(String(decoding: data, as: UTF8.self)).compactMap { note in
            guard let id = note.id, seen.insert(id).inserted,
                  let json = try? encoder.encode(note) else { return nil }
            return IndexRecord(key: id, value: String(decoding: json, as: UTF8.self))
        }
    }

    /// 索引中的所有卡片 note
    public static func notes(in index: VaultIndex) async throws -> [(path: String, note: CardNote)] {
        let decoder = JSONDecoder()
        return try await index.records(contributorID).compactMap { item in
            guard let note = try? decoder.decode(CardNote.self, from: Data(item.record.value.utf8)) else { return nil }
            return (item.path, note)
        }
    }
}

/// 替缺少 `^id` 的卡片補上 id，並修正重複的 id（見 `CardIDs.fill`）。
public struct CardIDFixer: ContentFixer {
    public init() {}

    public func fix(path: String, kindID: String, data: Data, index: VaultIndex) async -> Data? {
        guard kindID == markdownKindID else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard !CardSyntax.parse(text).isEmpty else { return nil }
        let elsewhere = Set(((try? await index.records(CardIndexer.contributorID)) ?? [])
            .filter { $0.path != path }.map(\.record.key))
        return CardIDs.fill(text, path: path, takenElsewhere: elsewhere.contains).map { Data($0.utf8) }
    }
}
