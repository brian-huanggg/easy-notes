import Testing
@testable import Flashcards

struct AnkiExportTests {
    static func note(_ line: String, path: String = "日文/N2/文法.md") -> (path: String, note: CardNote) {
        (path, CardSyntax.parse(line)[0])
    }

    /// 三種類型各一個檔；guid = `^id`、資料夾 → `A::B`、標籤的 `/` → `::`
    @Test func splitsByNoteType() throws {
        let notes = [
            Self.note("光合作用發生在 :: **葉綠體** ^c-a1b2c3"),
            Self.note("中文 ;; Chinese ^c-d4e5f6", path: "雜記.md"),
            Self.note("{{粒線體}}是{{細胞的發電廠}} ^c-g7h8i9"),
            Self.note("還沒有 id :: 不匯出"),
        ]
        let files = AnkiExport.files(notes, tags: ["日文/N2/文法.md": ["考試/期中", "N2"]])
        #expect(files.map(\.name) == ["basic.txt", "basic-and-reversed.txt", "cloze.txt"])
        #expect(files.map(\.noteCount) == [1, 1, 1])
        let header = "#separator:tab\n#html:true\n#guid column:1\n#deck column:2\n#tags column:5\n"
        #expect(files[0].text == header + "c-a1b2c3\t日文::N2\t光合作用發生在\t<b>葉綠體</b>\t考試::期中 N2\n")
        #expect(files[1].text == header + "c-d4e5f6\t\t中文\tChinese\t\n")
        #expect(files[2].text == header + "c-g7h8i9\t日文::N2\t{{c1::粒線體}}是{{c2::細胞的發電廠}}\t\t考試::期中 N2\n")
    }

    @Test func markdownToHTML() {
        #expect(AnkiExport.html("a < b && *斜* ~~刪~~ ==螢光==") == "a &lt; b &amp;&amp; <i>斜</i> <s>刪</s> <mark>螢光</mark>")
        #expect(AnkiExport.html("`**不轉換** <x>` 與 **粗**") == "<code>**不轉換** &lt;x&gt;</code> 與 <b>粗</b>")
        #expect(AnkiExport.html("[[頁面]]、[[頁面|別名]]、[網站](https://example.com)")
                == "頁面、別名、<a href=\"https://example.com\">網站</a>")
        // 克漏字的內容也轉換；行內程式碼中的 {{}} 不算
        #expect(AnkiExport.cloze("{{**A**}} 與 `{{b}}`") == "{{c1::<b>A</b>}} 與 <code>{{b}}</code>")
    }

    /// 含引號的欄位加上引號，tab 換成空白
    @Test func quotesFields() {
        #expect(AnkiExport.field("他說 \"好\"") == "\"他說 \"\"好\"\"\"")
        #expect(AnkiExport.field("a\tb") == "a b")
        #expect(AnkiExport.tag("期中 考試/第一章") == "期中_考試::第一章")
    }
}
