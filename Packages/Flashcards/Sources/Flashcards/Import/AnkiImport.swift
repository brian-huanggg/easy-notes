import EasyNotesCore
import Foundation

/// 從 Anki 匯入的計畫（見 architecture/flashcards.md「Anki 匯入」）：分析時不寫入，產生要寫的檔案、媒體與複習紀錄。
/// 純邏輯，Vault 的讀取經由 `Environment`，方便測試
public struct AnkiImportPlan: Sendable {
    public struct File: Sendable, Equatable {
        public let path: String
        /// 寫入後的完整內容
        public let text: String
        public let created: Bool
        /// 新加入的 note 數
        public let added: Int
    }

    public struct Media: Sendable, Equatable {
        /// `.apkg` 中的檔名
        public let name: String
        /// Vault 內的路徑
        public let path: String
    }

    public enum Reason: Error, Sendable, Equatable {
        /// 不支援的筆記類型（名稱）
        case unsupportedType(String)
        case imageOcclusion
        /// 克漏字的答案跨行
        case clozeSpansLines
        /// 轉換後的語法解析出的類型或卡片數與 Anki 不同
        case unparsable
        case empty
    }

    public struct Skipped: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let deck: String
        /// 內容的前幾個字（純文字）
        public let preview: String
        public let reason: Reason
    }

    public internal(set) var files: [File] = []
    /// 要複製的媒體（同名且內容相同的不在這裡）
    public internal(set) var media: [Media] = []
    public internal(set) var entries: [ReviewEntry] = []
    public internal(set) var skipped: [Skipped] = []
    /// 牌組資料夾
    public internal(set) var decks: [String] = []
    public internal(set) var notesAdded = 0
    /// 已經匯入過（目標檔案中有相同內容）的 note
    public internal(set) var notesExisting = 0
    public internal(set) var cards = 0
    /// 引用了但 `.apkg` 中沒有的媒體檔
    public internal(set) var missingMedia: [String] = []
    public internal(set) var rolloverHour: Int?

    /// 分析需要的 Vault 狀態
    public struct Environment {
        /// Vault 內檔案的內容；不存在時為 nil
        public var read: (String) -> Data?
        /// 卡片 note 的 `^id` → 所在檔案（索引中的全部 note）
        public var noteIDs: [String: Set<String>]
        /// 目前暫停中的卡片
        public var suspended: Set<String>
        /// 沒有麵包屑的 note 放的檔名（不含副檔名）
        public var fallbackFileName: String

        public init(read: @escaping (String) -> Data?, noteIDs: [String: Set<String>], suspended: Set<String>,
                    fallbackFileName: String) {
            self.read = read
            self.noteIDs = noteIDs
            self.suspended = suspended
            self.fallbackFileName = fallbackFileName
        }
    }
}

enum AnkiImport {
    /// 一筆轉換好的 note
    struct Planned {
        let source: AnkiCollection.Note
        let cards: [AnkiCollection.Card]
        let type: CardType
        /// 克漏字：出現順序的編號（`c2` → 2）
        let clozeOrder: [Int]
        var lines: [String]
        let folder: String
        let fileStem: String
        let tags: [String]
        var media: [String]
    }

    static func plan(_ collection: AnkiCollection, hasMedia: (String) -> Bool, mediaData: (String) throws -> Data?,
                     environment env: AnkiImportPlan.Environment) throws -> AnkiImportPlan {
        var plan = AnkiImportPlan()
        plan.rolloverHour = collection.rolloverHour
        let cardsByNote = Dictionary(grouping: collection.cards, by: \.noteID)

        // 1. 轉換每一筆 note
        var planned: [Planned] = []
        for note in collection.notes {
            guard let cards = cardsByNote[note.id]?.sorted(by: { $0.ord < $1.ord }), let first = cards.first else { continue }
            switch convert(note, cards: cards, type: collection.noteTypes[note.typeID], fallbackHead: first.deck.last ?? "") {
            case let .success(item): planned.append(item)
            case let .failure(reason):
                plan.skipped.append(.init(id: note.id, deck: first.deck.joined(separator: "::"),
                                          preview: preview(note.fields.first ?? ""), reason: reason))
            }
        }

        // 2. 媒體：同名且內容相同的沿用，同名但內容不同的換一個名稱並改寫引用
        var renamed: [String: String] = [:]
        var targets = Set<String>()
        for name in Array(Set(planned.flatMap(\.media))).sorted() {
            guard hasMedia(name) else {
                plan.missingMedia.append(name)
                continue
            }
            let path = Attachments.embedPath(name)
            guard let existing = env.read(path) ?? Attachments.legacyPath(for: path).flatMap(env.read) else {
                plan.media.append(.init(name: name, path: path))
                targets.insert(path)
                continue
            }
            if try mediaData(name) == existing { continue }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var n = 2
            var candidate: String
            repeat {
                candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            } while env.read(Attachments.embedPath(candidate)) != nil || targets.contains(Attachments.embedPath(candidate))
            renamed[name] = candidate
            plan.media.append(.init(name: name, path: Attachments.embedPath(candidate)))
            targets.insert(Attachments.embedPath(candidate))
        }
        if !renamed.isEmpty {
            for i in planned.indices {
                for (old, new) in renamed {
                    planned[i].lines = planned[i].lines.map { $0.replacingOccurrences(of: "![[\(old)]]", with: "![[\(new)]]") }
                }
            }
        }

        // 3. 依檔案寫入：已經有相同內容的 note 不再寫入；補上 `^id`；Anki 卡片對應到卡片 id
        let reviews = Dictionary(grouping: collection.reviews, by: \.cardID)
        var assigned: [String: String] = [:] // 這次匯入補上的 id → 檔案
        var deckFolders = Set<String>()
        let byFile = Dictionary(grouping: planned) { item -> String in
            let folder = item.folder
            let stem = item.fileStem.isEmpty ? env.fallbackFileName : item.fileStem
            let name = VaultFS.safeFileName(stem) + ".md" // l10n:fixed
            return folder.isEmpty ? name : folder + "/" + name
        }
        for path in byFile.keys.sorted() {
            let items = byFile[path]!.sorted { $0.source.id < $1.source.id }
            deckFolders.insert((path as NSString).deletingLastPathComponent)
            let original = env.read(path).map { String(decoding: $0, as: UTF8.self) }
            let existing = CardSyntax.parse(original ?? "")
            var text = original ?? ""
            var appended: [(item: Planned, line: Int)] = []
            var existingMatches: [(item: Planned, note: CardNote)] = []
            var tags = Set<String>()
            for item in items {
                tags.formUnion(item.tags)
                let alone = CardSyntax.parse(item.lines.joined(separator: "\n")).first!
                if let match = existing.first(where: { $0.id != nil && sameContent($0, alone) }) {
                    existingMatches.append((item, match))
                    continue
                }
                appended.append((item, -1))
            }
            if original == nil {
                text = "---\ntags: [\(tags.sorted().joined(separator: ", "))]\n---\n" // l10n:fixed
            } else if let merged = mergeTags(text, tags) {
                text = merged
            }
            for i in appended.indices {
                text = text.trimmingCharacters(in: .newlines) + "\n\n"
                appended[i].line = text.components(separatedBy: "\n").count - 1
                text += appended[i].item.lines.joined(separator: "\n")
            }
            if !text.hasSuffix("\n") { text += "\n" }
            let filled = CardIDs.fill(text, path: path) { id in
                if let elsewhere = assigned[id], elsewhere != path { return true }
                return env.noteIDs[id].map { !$0.subtracting([path]).isEmpty } ?? false
            } ?? text
            let parsed = Dictionary(CardSyntax.parse(filled).map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
            for note in parsed.values { if let id = note.id { assigned[id] = path } }

            var mapped: [(Planned, [String])] = existingMatches.map { ($0.item, $0.note.cardIDs) }
            for (item, line) in appended {
                guard let note = parsed[line], note.type == item.type else { continue }
                mapped.append((item, note.cardIDs))
            }
            plan.notesExisting += existingMatches.count
            plan.notesAdded += appended.count
            if filled != (original ?? "") {
                plan.files.append(.init(path: path, text: filled, created: original == nil, added: appended.count))
            }
            for (item, cardIDs) in mapped {
                for card in item.cards {
                    let targets = targetIDs(card, item: item, cardIDs: cardIDs)
                    plan.cards += targets.count
                    for cid in targets {
                        plan.entries += entries(for: card, cid: cid, reviews: reviews[card.id] ?? [],
                                                suspended: env.suspended.contains(cid))
                    }
                }
            }
        }
        plan.decks = deckFolders.sorted()
        plan.entries.sort { ($0.id, $0.cid) < ($1.id, $1.cid) }
        return plan
    }

    // MARK: 轉換

    static func convert(_ note: AnkiCollection.Note, cards: [AnkiCollection.Card], type noteType: AnkiCollection.NoteType?,
                        fallbackHead: String) -> Result<Planned, AnkiImportPlan.Reason> {
        guard let noteType else { return .failure(.unsupportedType("?")) }
        let deck = cards[0].deck
        var fields = note.fields
        while fields.count < noteType.fields.count { fields.append("") }
        let type: CardType
        if noteType.cloze {
            guard !fields[0].contains("image-occlusion:") else { return .failure(.imageOcclusion) }
            type = .cloze
        } else if noteType.fields.count == 2, noteType.templates == 1 || noteType.templates == 2 {
            type = noteType.templates == 1 ? .forward : .bidirectional
        } else {
            return .failure(.unsupportedType(noteType.name))
        }

        let (crumbs, firstField) = AnkiHTML.breadcrumb(fields[0])
        var media: [String] = []
        var front: [String]
        var back: [String]
        var order: [Int] = []
        if type == .cloze {
            // 答案結尾的換行移到克漏字外（克漏字不能跨行）
            let raw = firstField.replacing(/((?:<br\s*\/?>|<div>|&nbsp;|\s)+)\}\}/) { "}}" + $0.1 }
            let converted = AnkiHTML.markdown(raw)
            media += converted.media
            var text = liftClozesOutOfCode(converted.markdown)
            order = text.matches(of: /\{\{c(\d+)::/).compactMap { Int($0.1) }
            text = text.replacing(/\{\{c\d+::(.*?)\}\}/) { match in
                // `答案::提示` 只留答案
                let answer = match.1.components(separatedBy: "::").first ?? ""
                return "{{" + answer + "}}"
            }
            if text.contains(/\{\{c\d+::/) { return .failure(.clozeSpansLines) }
            guard !order.isEmpty else { return .failure(.empty) }
            front = text.components(separatedBy: "\n")
            let extra = fields.count > 1 ? AnkiHTML.markdown(fields[1]) : AnkiHTML.Result(markdown: "", media: [])
            media += extra.media
            back = extra.markdown.isEmpty ? [] : extra.markdown.components(separatedBy: "\n")
        } else {
            let f = AnkiHTML.markdown(firstField)
            let b = AnkiHTML.markdown(fields[1])
            media += f.media + b.media
            guard !f.markdown.isEmpty, !b.markdown.isEmpty else { return .failure(.empty) }
            front = f.markdown.components(separatedBy: "\n")
            back = b.markdown.components(separatedBy: "\n")
        }

        // 首行：正面第一行是清單、圖片或空白時改用麵包屑的最後一段（沒有時用牌組名稱）
        var head = front.removeFirst()
        if head.trimmingCharacters(in: .whitespaces).isEmpty || head.hasPrefix("![[")
            || head.prefixMatch(of: /[ \t]*(?:[-*+]|\d+[.)])[ \t]/) != nil {
            if !head.trimmingCharacters(in: .whitespaces).isEmpty { front.insert(head, at: 0) }
            head = crumbs.last ?? fallbackHead
        }
        while front.first?.isEmpty == true { front.removeFirst() }

        let indent = { (lines: [String]) in lines.map { $0.isEmpty ? "" : "  " + $0 } }
        var lines: [String]
        switch type {
        case .cloze:
            if front.isEmpty, back.isEmpty {
                lines = ["- " + head]
            } else {
                lines = ["- \(head) ::"] + indent(front)
                if !back.isEmpty { lines += ["  ::"] + indent(back) }
            }
        case .forward, .bidirectional:
            let separator = type == .forward ? "::" : ";;"
            if front.isEmpty, back.count == 1 {
                lines = ["- \(head) \(separator) \(back[0])"]
            } else {
                lines = ["- \(head) \(separator)"] + indent(front)
                if !front.isEmpty { lines.append("  ::") }
                lines += indent(back)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }

        // 解析出的類型與卡片數要與 Anki 相同
        let parsed = CardSyntax.parse(lines.joined(separator: "\n"))
        guard parsed.count == 1, let result = parsed.first, result.type == type else { return .failure(.unparsable) }
        switch type {
        case .cloze: guard result.clozes.count == order.count else { return .failure(.unparsable) }
        case .forward, .bidirectional: break
        }

        let folder = deck.map(VaultFS.safeFileName) + crumbs.dropLast().map(VaultFS.safeFileName)
        return .success(Planned(source: note, cards: cards, type: type, clozeOrder: order, lines: lines,
                                folder: folder.joined(separator: "/"), fileStem: crumbs.last ?? "",
                                tags: note.tags.map(tag), media: media))
    }

    /// 行內程式碼與只有一行的程式碼區塊中的克漏字：改成程式碼在克漏字內（`` `a {{c1::b}}` `` → `` `a `{{c1::`b`}} ``）
    static func liftClozesOutOfCode(_ text: String) -> String {
        var s = text.replacing(/(?m)^```\n([^\n`]*\{\{c\d+::[^\n`]*\}\}[^\n`]*)\n```$/) { "`" + $0.1 + "`" }
        s = s.replacing(/`([^`\n]*\{\{c\d+::[^`\n]*?\}\}[^`\n]*)`/) { match in
            var out = ""
            var rest = Substring(match.1)
            while let cloze = rest.firstMatch(of: /\{\{(c\d+::)(.*?)\}\}/) {
                let before = rest[..<cloze.range.lowerBound]
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { out += "`\(before)`" } else { out += before }
                out += "{{\(cloze.1)`\(cloze.2.trimmingCharacters(in: .whitespaces))`}}"
                rest = rest[cloze.range.upperBound...]
            }
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { out += "`\(rest)`" } else { out += rest }
            return out
        }
        return s
    }

    /// Anki 的標籤 → EasyNotes 的標籤：階層 `a::b` → `a/b`，不允許的字元換成 `_`
    static func tag(_ anki: String) -> String {
        anki.replacingOccurrences(of: "::", with: "/").replacing(/[^\p{L}\p{N}_\/-]/, with: "_")
    }

    /// 內容的前幾個字（摘要中的略過清單）
    static func preview(_ html: String) -> String {
        let text = AnkiHTML.decodeEntities(html.replacing(/<[^>]*>/, with: " "))
            .replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    static func sameContent(_ a: CardNote, _ b: CardNote) -> Bool {
        a.type == b.type && a.front == b.front && a.back == b.back && a.clozes == b.clozes
    }

    /// frontmatter 的 `tags: [a, b]` 加入缺少的標籤；沒有這種寫法的 `tags` 時不改（回傳 nil）
    static func mergeTags(_ text: String, _ tags: Set<String>) -> String? {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex),
              let line = text[..<end.lowerBound].firstMatch(of: /(?m)^tags:[ \t]*\[(.*)\][ \t]*$/) else { return nil }
        let current = line.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let missing = tags.subtracting(current).sorted()
        guard !missing.isEmpty else { return nil }
        var result = text
        result.replaceSubrange(line.range, with: "tags: [\((current + missing).joined(separator: ", "))]")
        return result
    }

    // MARK: 卡片對應與紀錄

    /// Anki 的一張卡片對應到的卡片 id：正向 / 雙向依 `ord`；克漏字依編號（同一個編號出現多次時對應到每一張）
    static func targetIDs(_ card: AnkiCollection.Card, item: Planned, cardIDs: [String]) -> [String] {
        switch item.type {
        case .forward, .bidirectional:
            return card.ord < cardIDs.count ? [cardIDs[card.ord]] : []
        case .cloze:
            return item.clozeOrder.indices.filter { item.clozeOrder[$0] == card.ord + 1 && $0 < cardIDs.count }.map { cardIDs[$0] }
        }
    }

    /// 複習紀錄：`type` 0–3 照原樣；Anki 中是新卡但有紀錄 → `reset`；暫停狀態與 EasyNotes 不同 → `suspend` / `unsuspend`
    static func entries(for card: AnkiCollection.Card, cid: String, reviews: [AnkiCollection.Review],
                        suspended: Bool) -> [ReviewEntry] {
        var result: [ReviewEntry] = reviews.compactMap { r in
            guard (1...4).contains(r.ease), let kind = ReviewEntry.Kind(rawValue: r.type), kind != .manual else { return nil }
            return ReviewEntry(id: r.id, cid: cid, ease: r.ease, ivl: r.ivl, lastIvl: r.lastIvl, time: r.time, type: kind)
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(card.modified))
        if card.type == 0, !result.isEmpty { result.append(.manual(.reset, cid: cid, at: modified)) }
        if card.queue == -1, !suspended { result.append(.manual(.suspend, cid: cid, at: modified)) }
        if card.queue != -1, suspended { result.append(.manual(.unsuspend, cid: cid, at: modified)) }
        return result
    }
}
