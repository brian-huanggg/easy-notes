import EasyNotesUI

/// 卡片解析、FSRS 排程、複習介面。不是檔案類型：卡片寫在 .md 裡，語法標示由 Markdown 外掛負責。
public enum FlashcardsPlugin: EasyNotesPlugin {
    public static func register(in registry: PluginRegistry) {
        registry.addIndexContributor(CardIndexer())
        registry.addContentFixer(CardIDFixer())
        registry.addVaultGuide(guide)
        registry.addSyncedMetaFolder(ReviewLog.metaFolder)
        registry.addController(ReviewStore.shared)
        registry.addPanel(id: "review", title: L("複習"), symbol: "rectangle.stack", badgeTint: Palette.cardDue,
                          badge: { ReviewStore.shared.dueCount }) { ReviewPanel() }
    }

    /// Vault 根目錄 `CLAUDE.md` 的卡片語法一節（l10n:fixed：給 Claude Code 讀，內容語言固定）
    static let guide = """
        ## 卡片（Flashcards）

        卡片直接寫在 md 裡，一行一張（Anki 的 note）：

        | 語法 | 產生 |
        | --- | --- |
        | `光合作用發生在 :: 葉綠體` | 正向一張 |
        | `中文 ;; Chinese` | 正向、反向各一張 |
        | `{{粒線體}}是{{細胞的發電廠}}` | 每個 `{{}}` 一張克漏字 |

        - `::`、`;;` 前後要有空白；有 `{{}}` 的行一律是克漏字。
        - 行首可以有清單、待辦、標題、引言標記（`- 問 :: 答`）。
        - 程式碼區塊、行內程式碼與 frontmatter 內不算卡片。
        - 只要寫語法就好，**不要自己加 `^id`**：App 會在行尾補上 `^c-xxxxxx`，它是卡片的身分，複習紀錄靠它對應。
        - 修改卡片文字或把整行搬到別的筆記時，保留行尾原本的 `^id`，複習歷史才會跟著走。
        - 牌組 = 資料夾（含子資料夾）；標籤只用來篩選。
        - 不要手動修改 `.easynotes/srs/` 下的檔案（複習紀錄與設定）。
        """
}
