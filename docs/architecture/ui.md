# 外殼、列表與編輯器（UI）

外殼依 `design/easy-notes-ui.pen`（節點 id 見 Roadmap「Phase 2.5」）；設計稿不改變資料模型與外掛邊界。

## 設計稿與 EasyNotes 模型的對應

| 設計稿 | EasyNotes 對應 |
| --- | --- |
| 側邊欄 Vault 標頭（名稱 + 帳號） | 單一 Vault，不可切換；帳號來自 Supabase Auth |
| Spaces | Vault 根目錄的第一層資料夾；`+` = 新增第一層資料夾 |
| All Documents / Recents | 索引的 `files` 表，依 `mtime` 排序 |
| Pinned（側邊欄與列表頁同一概念） | frontmatter `pinned: true`（跟著檔案同步、Claude Code 可讀寫） |
| Tags | 現有標籤索引 |
| 篩選 All / Notes / Boards / PDFs / Sheets | 依 Registry 中已註冊的 Kind 產生；尚未實作的外掛不顯示 |
| 類型顏色 `type-doc` / `type-board` / `type-pdf` / `type-csv` | 外掛註冊 Kind 時一併提供顏色，App 不寫死 |
| 卡片縮圖與副標（「CSV · 86 rows」「PDF · 18 pages」） | 各外掛的 DocumentPreviewProvider 產生縮圖與一行摘要 |
| New Document 選單（⌘N、⇧⌘N、匯入 PDF / CSV、新資料夾） | `addNewFile` 加上 `addImport`（把外部檔案複製進 Vault） |
| 文件 icon、封面、標籤 | frontmatter `icon`、`cover`（Vault 內圖片路徑）、`tags` |
| Review | Flashcards 外掛以 `addPanel` 註冊；沒有註冊時不顯示 |
| Recently Deleted（保留 30 天） | 「最近刪除」 |
| Synced · 2 min ago | 同步狀態（已同步 / 待上傳 / 衝突） |
| 資料夾圖示（`folder-open`） | 在 Finder 中顯示（iOS：在「檔案」App 中顯示） |
| Me（Mobile 分頁） | 帳號、同步面板、設定 |

## 設計系統

- Pen variables（`mode: light / dark`）轉成 `EasyNotesUI/DesignSystem/`：`Palette`、`KindTint`、`TextStyle`、`Metrics`、`ThemeCSS` 與共用元件（Sidebar Item、Icon Button、Doc Card、Doc Row、Pin Card、Tab Bar、空狀態）。類型顏色由外掛註冊 Kind 時提供，App 與列表頁只讀 Registry。
- 同一組 tokens 由 `ThemeCSS.stylesheet()` 輸出成 CSS variables，WebEditorHost 以 user script 在頁面載入前注入 CM6（不經 Bridge）；WebView 自己跟隨系統深淺色。
- 字型：Pen 不支援蘋果字型，設計稿以 Inter 代替（`font-ui`、`font-doc`、`font-cjk`）。實作一律用系統字型：拉丁字 SF Pro、中文蘋方-繁（SwiftUI 預設；CM6 用 `-apple-system`），不打包 Inter；字級、字重、行高照設計稿。
- `DesignSystemGallery` 可在 Xcode Preview 或 `EASYNOTES_SNAPSHOT_DIR=… swift test` 輸出截圖，與設計稿比對。

## 外殼與導覽

- 導覽 = `Route`（所有文件 / 最近 / 釘選 / 資料夾 / 標籤 / 檔案 / 外掛面板）＋上一頁 / 下一頁歷史（⌘[ / ⌘]）；App 啟動時顯示所有文件。iPhone 用底部分頁（Docs / Search / Spaces / Me），不用 `NavigationSplitView` 的摺疊。
- 外掛以 `addPanel` 加側邊欄項目，App 不寫死。反向連結 inspector 已移除（索引仍保留反向連結資料）。
- 介面語言統一繁體中文：App 宣告 `zh-Hant` 在地化，系統選單也是中文；側邊欄顯示「空間」「標籤」。
- 快捷鍵：⌘K 快速開啟（重用 FTS5 搜尋）、Markdown 的「[[連結]]」⇧⌘K、新筆記 ⌘N、新白板 ⇧⌘N、新資料夾 ⇧⌘F。
- 側邊欄檔案樹：Mac 雙擊檔案或資料夾就地改名（Return 確定、Esc 取消、失去焦點視為確定；檔案只改名稱，副檔名保留），右鍵「重新命名」仍是對話框。檔案與資料夾可拖到另一個資料夾，拖到「空間」標題 = 搬到 Vault 根目錄；搬移不改檔名，所以 `[[連結]]` 不必改寫；目的地有同名項目、或把資料夾拖進自己（含子資料夾）時不搬。伴隨檔、同步（保留 file id）、編輯器與導覽的處理與改名相同。拖曳內容是 Vault 相對路徑字串，放下時確認路徑存在才搬。
- 匯入的目的地 = 目前所在資料夾（資料夾頁 = 該資料夾、編輯器 = 文件所在資料夾、其他列表頁 = Vault 根目錄），不另設 `Inbox/`。

## 文件列表

- **釘選存 frontmatter `pinned: true`**：Claude Code 可直接讀寫，`.easynotes/` 不必加入同步。`DocumentKind.setPinned` 預設 nil = 不支援，列表的「釘選」選單只對支援的類型顯示；App 寫入後把 mtime 還原，釘選不會讓文件跑到「最近」最上面。白板之後改存 `customData`，PDF 等外掛完成再處理。釘選會替沒有 frontmatter 的 md 加上 frontmatter，所以 CM6 在游標不在區塊內時把它收合成一行屬性。
- `IndexEntry` 的 `icon`、`pinned`、`summary`（外掛提供一行摘要，Core 不認識「字數」）；索引另存內容 `hash` 作為預覽快取的 key。
- `addKind(..., name:)` 提供篩選 chip 的名稱；Mobile 與 Desktop 的篩選相同（全部 + 已註冊類型）。
- 列表的文件與資料夾有 hover 狀態：卡片加深邊框並浮起、列加 `bg-hover`、游標變手指；iPad 指標用系統 highlight。

## 編輯器文件頭與工具列

- **文件頭是 CM6 decorations**：封面 + icon 為檔案開頭的 block widget；標題就是第一行 `#`（一般文字，組字不受影響，索引規則不變）；meta 列（標籤、「N 分鐘前編輯」，不顯示閱讀時間）為標題行之後的 block widget。游標進入 frontmatter 才顯示原始 YAML。
- **封面** `cover: Attachments/xxx.jpg`（Vault 內路徑）：從 Vault 外選的圖片（含貼上剪貼簿）複製到根目錄 `Attachments/`，重名加序號。舊版的 `附件/` 不搬動也不改寫連結：`vault://` 在 `Attachments/` 找不到檔案時改找 `附件/`，所以只寫檔名的 `![[x.png]]` 與明確寫 `附件/` 的舊連結都照常顯示。更換封面 / icon 走一般寫檔路徑（更新 mtime、進同步），與釘選不同。圖片經 `vault://` 讀取，只允許 Vault 內路徑。
- **icon** 支援 Emoji 與 SF Symbols（不打包 Lucide）：`icon: 🗺` 或 `icon: sf:map`，Core 只存字串。選單為「圖示 | 表情符號」；Apple 沒有列出所有 SF Symbols 的 API，所以內建常用清單，搜尋框也接受完整名稱；名稱不存在時顯示類型預設圖示。列表卡片：emoji 接在標題前、SF Symbol 取代類型圖示；編輯器經 `symbol:///<名稱>` 顯示。在 App 外（例如 Obsidian）只會看到 `sf:` 文字。
- **連結卡片**：`[[連結]]` 獨占一行時顯示為卡片（含目標的類型圖示），相鄰的多行並排；設計稿的「關聯頁面」就是這個內文樣式，不是自動產生的區塊。目標的類型、摘要、時間由 `EditorController.linkTargetsChanged` 傳 `LinkTarget`；WebView 沒有 SF Symbols，圖示由 Swift 依 Registry 的 symbol 畫成 PNG。
- **工具列**：浮動格式工具列（Desktop）與 iOS Format Bar 共用 `FormatBar`，原生 SwiftUI，按下時送 `exec`，不在打字路徑上；編輯器工具列（儲存狀態、釘選、更多）放在 App，所有檔案類型共用。
