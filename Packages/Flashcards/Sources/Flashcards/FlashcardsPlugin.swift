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

    /// Vault 根目錄 `CLAUDE.md` 的卡片語法一節（l10n:fixed：給 Claude Code 讀，內容固定用英文）
    static let guide = """
        ## Cards (Flashcards)

        Cards are written directly in markdown, one per line (an Anki "note"):

        | Syntax | Produces |
        | --- | --- |
        | `Photosynthesis takes place in :: chloroplasts` | one forward card |
        | `中文 ;; Chinese` | one forward and one reverse card |
        | `{{Mitochondria}} are the {{powerhouse of the cell}}` | one cloze card per `{{}}` |

        - `::` and `;;` need spaces on both sides; a line containing `{{}}` is always a cloze card.
        - A line may start with a list, task, heading or quote marker (`- Question :: Answer`).
        - Code blocks, inline code and frontmatter are not parsed for cards.
        - Write the syntax only and **do not add `^id` yourself**: the app appends `^c-xxxxxx` to the end of the line. It is the card's identity, and review history is matched through it.
        - When editing a card's text or moving the whole line to another note, keep the trailing `^id` so the review history follows the card.
        - A deck is a folder (including subfolders); tags are only used for filtering.
        - Do not modify files under `.easynotes/srs/` (review logs and settings).
        """
}
