import EasyNotesCore
import Foundation
import Testing
@testable import Flashcards

struct AnkiHTMLTests {
    static func md(_ html: String) -> String { AnkiHTML.markdown(html).markdown }

    @Test func blocks() {
        #expect(Self.md("a<br>b") == "a\nb")
        #expect(Self.md("<div>a</div><div>b</div>") == "a\nb")
        #expect(Self.md("a<br><br><br><br>b") == "a\n\nb")
        #expect(Self.md("<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>") == "- a\n  - b\n- c")
        #expect(Self.md("<ol><li>a</li><li>b</li></ol>") == "1. a\n2. b")
        // Anki 常見的 `<li><div>&nbsp;</div>…` 與清單之間多餘的 <br>
        #expect(Self.md("<ul><li><div>&nbsp;</div>x</li></ul><br><ul><li>y</li></ul>") == "- x\n- y")
        #expect(Self.md("<pre><code>a\n  b</code></pre>") == "```\na\n  b\n```")
        #expect(Self.md("x<pre><br></pre>") == "x")
    }

    @Test func inline() {
        // 樣式跨換行時每行各自成對；頭尾空白移到樣式外
        #expect(Self.md("<b>x<br>y</b>") == "**x**\n**y**")
        #expect(Self.md("<b> bold </b>text") == "**bold** text")
        #expect(Self.md("<i>i</i> <s>s</s> <code>c</code>") == "*i* ~~s~~ `c`")
        #expect(Self.md("<a href=\"https://e.com\">site</a>") == "[site](https://e.com)")
        #expect(Self.md("<span style=\"color: red\"><u>plain</u></span>") == "plain")
        #expect(Self.md("&lt;tag&gt; &amp; &#x4E2D;&#25991; &nbsp;x &unknown;") == "<tag> & 中文  x &unknown;")
        #expect(Self.md("a <!-- comment --> b") == "a  b")
        #expect(Self.md("1 < 2") == "1 < 2")
    }

    @Test func mathAndDollars() {
        #expect(Self.md("\\(x^2\\) costs $5") == "$x^2$ costs \\$5")
        #expect(Self.md("\\[ \\int x \\]") == "$$\\int x$$")
        #expect(Self.md("[$]a[/$] [$$]b[/$$]") == "$a$ $$b$$")
        #expect(Self.md("<code>$x</code>") == "`$x`")
    }

    @Test func media() {
        let result = AnkiHTML.markdown("see<img src=\"a b.png\">and [sound:x.mp3]<img src=\"../evil.png\">")
        #expect(result.markdown == "see\n![[a b.png]]\nand ![[x.mp3]]\n![[evil.png]]")
        #expect(result.media == ["a b.png", "evil.png", "x.mp3"])
    }

    @Test func breadcrumb() {
        let (crumbs, rest) = AnkiHTML.breadcrumb("Math &gt; Calculus &gt;&nbsp;Limits<br><br>body")
        #expect(crumbs == ["Math", "Calculus", "Limits"])
        #expect(rest == "body")
        #expect(AnkiHTML.breadcrumb("Quote<br>body").crumbs.isEmpty)
        #expect(AnkiHTML.breadcrumb("a &gt; b without break").crumbs.isEmpty)
    }

    @Test func clozesInCode() {
        #expect(AnkiImport.liftClozesOutOfCode("Run `ps {{c1::aux}}` now") == "Run `ps `{{c1::`aux`}} now")
        #expect(AnkiImport.liftClozesOutOfCode("`{{c1::/x}}`.") == "{{c1::`/x`}}.")
        #expect(AnkiImport.liftClozesOutOfCode("```\n{{c1::kubectl get pods}}\n```") == "{{c1::`kubectl get pods`}}")
    }

    @Test func tags() {
        #expect(AnkiImport.tag("lang::zh") == "lang/zh")
        #expect(AnkiImport.tag("a.b+c") == "a_b_c")
    }
}

struct AnkiImportTests {
    static func fixture(_ name: String) throws -> AnkiPackage {
        try AnkiPackage(url: Bundle.module.url(forResource: name, withExtension: "apkg", subdirectory: "Fixtures")!)
    }

    /// 記憶體中的 Vault
    final class FakeVault {
        var files: [String: Data] = [:]
        var suspended: Set<String> = []

        var environment: AnkiImportPlan.Environment {
            var ids: [String: Set<String>] = [:]
            for (path, data) in files where path.hasSuffix(".md") {
                for note in CardSyntax.parse(String(decoding: data, as: UTF8.self)) {
                    if let id = note.id { ids[id, default: []].insert(path) }
                }
            }
            return .init(read: { [files] in files[$0] }, noteIDs: ids, suspended: suspended, fallbackFileName: "Anki 匯入")
        }

        func plan(_ package: AnkiPackage) throws -> AnkiImportPlan {
            try AnkiImport.plan(package.collection, hasMedia: { package.resolve($0) != nil }, mediaData: package.mediaData,
                                environment: environment)
        }

        func apply(_ plan: AnkiImportPlan, _ package: AnkiPackage) throws {
            for media in plan.media { files[media.path] = try package.mediaData(media.name) }
            for file in plan.files { files[file.path] = Data(file.text.utf8) }
        }

        func text(_ path: String) -> String { String(decoding: files[path] ?? Data(), as: UTF8.self) }
    }

    /// 去掉 `^id` 方便比對
    static func strip(_ text: String) -> String {
        text.replacing(/\ \^c-[a-z0-9]{6}/, with: "")
    }

    @Test(arguments: ["anki-modern", "anki-legacy"])
    func importsFixture(_ name: String) throws {
        let package = try Self.fixture(name)
        #expect(package.collection.notes.count == 10)
        #expect(package.mediaNames == ["rule.png", "a.mp3"])
        #expect(try package.mediaData("rule.png")?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(package.collection.rolloverHour == (name == "anki-modern" ? 6 : 5))

        let vault = FakeVault()
        let plan = try vault.plan(package)
        #expect(plan.skipped.map(\.id) == [1007, 1008, 1009])
        #expect(plan.skipped.map(\.reason) == [.unsupportedType("Option"), .imageOcclusion, .clozeSpansLines])
        #expect(plan.notesAdded == 7)
        #expect(plan.notesExisting == 0)
        #expect(plan.cards == 9)
        #expect(plan.decks == ["Lang", "Lang/English", "Lang/English/English", "Math", "Math/Math"])
        #expect(plan.media.map(\.path).sorted() == ["Attachments/a.mp3", "Attachments/rule.png"])
        #expect(plan.missingMedia.isEmpty)
        #expect(plan.files.allSatisfy { $0.created })
        try vault.apply(plan, package)

        #expect(Self.strip(vault.text("Lang/English/English/Vocab.md")) == "---\ntags: [vocab]\n---\n\n- apple :: 蘋果\n")
        #expect(Self.strip(vault.text("Lang/Anki 匯入.md")) == "---\ntags: [lang/zh]\n---\n\n- 中文 ;; Chinese\n")
        #expect(Self.strip(vault.text("Lang/English/Anki 匯入.md")) == "---\ntags: []\n---\n\n- Listen ![[a.mp3]] :: hello & bye\n")
        #expect(Self.strip(vault.text("Math/Math/Calculus.md")) == """
            ---
            tags: [math]
            ---

            - $\\frac{d}{dx}x^2$ = {{$2x$}} and {{linear}} ::
              ::
              - power rule

            - List the **rules** ::
              ![[rule.png]]
              ::
              - **Power**
                - costs \\$5
              - Chain

            """)
        #expect(Self.strip(vault.text("Math/Anki 匯入.md")) == "---\ntags: []\n---\n\n- Run `ps `{{`aux`}} now\n\n- {{`kubectl get pods`}}\n")

        // 卡片 id 與 CardIDFixer 相同：補過的檔案再補一次不會改變
        for path in vault.files.keys where path.hasSuffix(".md") {
            #expect(CardIDs.fill(vault.text(path), path: path) == nil)
        }

        // 複習紀錄：Learning / Review 照原樣、手動調整略過；暫停 → suspend、Forget 過 → reset
        let notes = vault.files.keys.filter { $0.hasSuffix(".md") }.flatMap { CardSyntax.parse(vault.text($0)) }
        func id(_ front: String) -> String { notes.first { $0.front.hasPrefix(front) }!.id! }
        let byCard = Dictionary(grouping: plan.entries, by: \.cid)
        #expect(byCard[id("apple")]?.map(\.type) == [.learning, .review, .manual])
        #expect(byCard[id("apple")]?.last?.op == .suspend)
        #expect(byCard[id("中文") + ":r"]?.map(\.op) == [nil, .reset])
        #expect(byCard[id("$\\frac") + ":2"]?.map(\.ivl) == [-600, 1])
        #expect(byCard[id("List the")]?.count == 1)
        #expect(plan.entries.count == 11)
        #expect(plan.entries == plan.entries.sorted { ($0.id, $0.cid) < ($1.id, $1.cid) })
    }

    /// 重複匯入：已有相同內容的 note 不再寫入，紀錄對應到同一張卡片
    @Test func reimportIsIdempotent() throws {
        let package = try Self.fixture("anki-modern")
        let vault = FakeVault()
        let first = try vault.plan(package)
        try vault.apply(first, package)
        let before = vault.files

        vault.suspended = [first.entries.first { $0.op == .suspend }!.cid]
        let second = try vault.plan(package)
        #expect(second.files.isEmpty)
        #expect(second.media.isEmpty)
        #expect(second.notesAdded == 0)
        #expect(second.notesExisting == 7)
        #expect(Set(second.entries) == Set(first.entries.filter { $0.op != .suspend }))
        try vault.apply(second, package)
        #expect(vault.files == before)
    }

    /// 已有的檔案：加在檔尾、合併 frontmatter 的標籤，不動原本的內容
    @Test func appendsToExistingFile() throws {
        let package = try Self.fixture("anki-modern")
        let vault = FakeVault()
        vault.files["Lang/Anki 匯入.md"] = Data("---\ntags: [mine]\n---\n\n我的 :: 卡片 ^c-aaaaaa\n".utf8)
        let plan = try vault.plan(package)
        let file = try #require(plan.files.first { $0.path == "Lang/Anki 匯入.md" })
        #expect(!file.created)
        #expect(Self.strip(file.text) == "---\ntags: [mine, lang/zh]\n---\n\n我的 :: 卡片\n\n- 中文 ;; Chinese\n")
        #expect(file.text.contains("^c-aaaaaa"))
    }

    /// 媒體：同名同內容沿用；同名不同內容換名稱並改寫引用
    @Test func mediaConflicts() throws {
        let package = try Self.fixture("anki-modern")
        let same = FakeVault()
        same.files["Attachments/rule.png"] = try package.mediaData("rule.png")
        #expect(try same.plan(package).media.map(\.path) == ["Attachments/a.mp3"])

        let different = FakeVault()
        different.files["Attachments/rule.png"] = Data("other".utf8)
        let plan = try different.plan(package)
        #expect(plan.media.map(\.path).sorted() == ["Attachments/a.mp3", "Attachments/rule 2.png"])
        #expect(plan.files.first { $0.path == "Math/Math/Calculus.md" }!.text.contains("![[rule 2.png]]"))
    }

    /// 筆記引用的檔名大小寫與存檔的不同時（Anki 在不分大小寫的檔案系統上），唯一符合的就是它
    @Test func mediaNameIsCaseInsensitive() throws {
        let package = try Self.fixture("anki-modern")
        #expect(package.resolve("RULE.PNG") == "rule.png")
        #expect(try package.mediaData("Rule.png") != nil)
        #expect(package.resolve("missing.png") == nil)
    }

    @Test func rejectsNonPackages() {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-anki-\(UUID().uuidString).apkg")
        try? Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try AnkiPackage(url: url) }
    }

    /// 真實資料的驗證（只在設定 `ANKI_APKG` 時執行）：匯入結果寫到 `ANKI_OUT`，
    /// 複習紀錄寫成 `.easynotes/srs/import.jsonl`，再由外部腳本重播並與 Anki 比對
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANKI_APKG"] != nil))
    func realPackage() throws {
        let env = ProcessInfo.processInfo.environment
        let package = try AnkiPackage(url: URL(fileURLWithPath: env["ANKI_APKG"]!))
        let vault = FakeVault()
        let plan = try vault.plan(package)
        try vault.apply(plan, package)
        let out = URL(fileURLWithPath: env["ANKI_OUT"] ?? NSTemporaryDirectory() + "anki-import")
        try? FileManager.default.removeItem(at: out)
        for (path, data) in vault.files {
            let url = out.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let log = out.appending(path: ".easynotes/srs/import.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.entries.map(\.line).joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        print("files \(plan.files.count) notes \(plan.notesAdded) cards \(plan.cards) entries \(plan.entries.count)",
              "media \(plan.media.count) missing \(plan.missingMedia) rollover \(plan.rolloverHour ?? -1)")
        for skipped in plan.skipped { print("skipped", skipped.deck, skipped.reason, skipped.preview) }
    }
}
