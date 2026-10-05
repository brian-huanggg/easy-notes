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

    /// 公式轉成 Anki 的 MathJax 分隔符；克漏字內的 `}}` 拆開
    @Test func mathToMathJax() {
        #expect(AnkiExport.html("$a<b$ 與 **$$x^2$$**") == "\\(a&lt;b\\) 與 <b>\\[x^2\\]</b>")
        #expect(AnkiExport.html("$*不轉換*$ 與 \\$5") == "\\(*不轉換*\\) 與 $5")
        #expect(AnkiExport.cloze("{{$\\frac{a}{b^{2}}$}} 與 $\\sqrt{x}$")
                == "{{c1::\\(\\frac{a}{b^{2} }\\)}} 與 \\(\\sqrt{x}\\)")
    }

    /// 含引號的欄位加上引號，tab 換成空白
    @Test func quotesFields() {
        #expect(AnkiExport.field("他說 \"好\"") == "\"他說 \"\"好\"\"\"")
        #expect(AnkiExport.field("a\tb") == "a b")
        #expect(AnkiExport.tag("期中 考試/第一章") == "期中_考試::第一章")
    }

    @Test func multilineContent() {
        let text = "問題\n第二行\n\n- 一\n  - 二\n1. 三\n![[a b.png|300]]\n```\nx < y\n  z\n```\n結尾"
        #expect(AnkiExport.content(text) == "問題<br>第二行<ul><li>一</li><ul><li>二</li></ul></ul><ol><li>三</li></ol>"
            + "<img src=\"a b.png\"><pre><code>x &lt; y<br>  z</code></pre>結尾")
    }

    @Test func multilineClozeNumbersAcrossLines() {
        let note = CardSyntax.parse("- 理論 :: ^c-aaaaaa\n  - {{信任}}\n  - {{親密}}\n  ::\n  補充").first!
        let row = AnkiExport.row(note, path: "a.md", tags: [])
        #expect(row[2] == "理論<ul><li>{{c1::信任}}</li><li>{{c2::親密}}</li></ul>")
        #expect(row[3] == "補充")
    }
}
