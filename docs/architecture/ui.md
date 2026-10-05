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

- **Accessibility identifier**：外殼中 E2E 會操作或檢查的元素（側邊欄項目與檔案樹、列表的文件與篩選、工具列、選單項目、⌘K、編輯器容器）掛 `A11yID` 的 identifier（`App/Support/UITestContract.swift`）。容器用 `.accessibilityElement(children: .contain)` 再掛 identifier，才不會蓋掉子元素的 identifier。新增這類元素時一併加上。

- 導覽 = `Route`（所有文件 / 最近 / 釘選 / 資料夾 / 標籤 / 檔案 / 外掛面板）＋上一頁 / 下一頁歷史（⌘[ / ⌘]）；App 啟動時顯示所有文件。iPhone 用底部分頁（Docs / Search / Spaces / Me），不用 `NavigationSplitView` 的摺疊。
- **分頁（Mac / iPad，iPhone 不做）**：內容區上方的分頁列（`DocumentTabBar`，多於一個分頁才顯示）。`TabSet<State>`（EasyNotesUI，泛型、純邏輯）只管分頁清單與目前分頁；`VaultStore` 的 `TabState` = 位置 + 該分頁自己的上一頁 / 下一頁，目前分頁的值與 `route`、`backStack`、`forwardStack` 同步（didSet）。**背景分頁不持有編輯器**：切換 = 載入該分頁的 `Route`，沿用原本的編輯器生命週期（Markdown 換 `EditorState`、其他外掛重建），所以分頁數不影響記憶體。
  - 開啟檔案（側邊欄、列表、⌘K、`[[連結]]`、新增、匯入）預設開在新分頁（目前分頁右邊）；檔案已在某個分頁開著就切過去，不重複。資料夾、標籤、列表、外掛面板在目前分頁內導覽，歷史照常。
  - 改名 / 搬移更新所有分頁；刪除檔案或資料夾時，指向它的背景分頁直接關閉，目前分頁回到上一層。關閉最後一個分頁 = 換成「所有文件」。關閉檔案分頁後，若沒有別處開著它，通知編輯器丟掉保留的狀態。
  - 分頁清單存在 `UserDefaults`（跟著裝置，不進 Vault、不同步），只存位置不存歷史；下次啟動第一次顯示 SplitShell 時還原，檔案已不存在的略過。E2E（`-EasyNotesVaultRoot`、`-EasyNotesOpen`）不還原也不保留。
  - 快捷鍵：⌘T 新分頁、⌘W 關閉、⇧⌘] / ⇧⌘[ 下一個 / 上一個分頁。
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

## 手寫工具列（白板、PDF 共用，GoodNotes 式）

- **兩層**：上方一排（導覽列下方，`safeAreaInset(edge: .top)`）是工具；選了畫筆類工具時，下面浮著一條膠囊（畫筆種類、粗細、顏色），以及左邊的 Undo / Redo 膠囊。浮動列蓋在內容上、不改畫布的 inset，所以切換工具時畫面不跳動；空白處不攔觸控。再按一次已選的工具可以收起 / 叫回膠囊。
- **上方一排的版面**：工具置中，右側放與目前選取或文件有關的動作（白板的樣式 / 再製 / 刪除、PDF 的匯出）。工具依序是「選取（離開手寫）| 畫筆、螢光筆、橡皮擦、套索 | 外掛自己的插入工具」。
- **不用 `PKToolPicker`**：系統工具盤是浮動面板，位置與樣式無法放進工具列。改由 EasyNotesUI 的共用元件自己設定 `PKCanvasView.tool`：
  - `InkSettings`（`@Observable`、`@MainActor`，單例）：目前的手寫工具（畫筆 / 螢光筆 / 橡皮擦 / 套索）、畫筆種類、各工具的顏色與粗細、使用者加的顏色。存在 `UserDefaults`（App 偏好，不進 Vault、不同步），白板與 PDF 共用：在 PDF 選的筆換到白板還是同一支。手寫模式的開關仍由各編輯器自己記（白板 `BoardEditor.inking`、PDF 檢視器的狀態）。
  - **畫筆種類**：鋼筆（`pen`）、原子筆（`monoline`）、鉛筆（`pencil`）；螢光筆是 `marker`。只用這四種墨水（其他墨水存成 freedraw 會失真）。
  - **粗細**：三段，墨水的 `defaultWidth` × 0.5 / 1 / 2（夾在 `validWidthRange` 內），各工具各記一段。
  - **顏色**：每個工具 5 個預設色 + 使用者加的顏色（「+」開系統顏色選擇器，最多 5 個，長按刪除）。畫筆預設 `#1e1e1e`、`#1971c2`、`#e03131`、`#2f9e44`、`#f08c00`；螢光筆 `#ffd43b`、`#69db7c`、`#74c0fc`、`#f783ac`、`#ffa94d`（透明度由 `marker` 墨水本身決定）。畫布固定淺色，顏色不隨深色模式反轉。
  - **橡皮擦**：整筆（`vector`）/ 部分（`bitmap`，三段粗細）。部分擦除切開的筆畫仍是一般 `PKStroke`，照常存成 freedraw。
  - 尺（`PKToolPicker` 的尺）不再提供：直線改用「停住變直線」。
- **Pencil 點兩下**（`UIPencilInteraction`，取代工具盤原本的行為）：依系統設定，「切換橡皮擦」= 橡皮擦 ⇄ 上一個工具、「切換上一個工具」= 與上一個工具互換、「顯示色盤」= 收起 / 叫回膠囊；不在手寫模式時不處理。
- **停住變直線（Apple 備忘錄 / GoodNotes 式）**：畫一筆後筆尖停住約 0.5 秒（移動 < 3 螢幕點），這一筆變成「起點 → 目前位置」的直線；不放開筆可以繼續移動終點，角度接近水平、垂直或 45° 時（±3°）吸附。實作在 EasyNotesUI 的 `StraightLineAssist`（iOS），白板與 PDF 的 `PKCanvasView` 各掛一個：
  - 觸控以一個只觀察、不攔截的手勢辨識器取得（`cancelsTouchesInView = false`，與所有手勢同時辨識），只看 `drawingPolicy` 允許書寫的觸控、只在畫筆 / 螢光筆時作用。筆畫長度不到 12 螢幕點時不觸發（點一下停住不會變直線）。
  - 觸發時把 `drawingGestureRecognizer` 停用再開啟，取消 PencilKit 進行中的筆畫；若取消後 PencilKit 仍留下這一筆，就還原成開始時的 `drawing`。調整期間在畫布上方用一條 `CAShapeLayer` 預覽（顏色、粗細與墨水相同），放開時才把直線 `PKStroke`（同一種墨水、顏色與粗細，沿線每 2 點一個控制點）加進 `drawing`。
  - 調整中的 `drawing` 變動不寫回（宿主檢查 `isAdjusting`），放開後的那一次變動才寫回，所以模型只看到「多了一條直線」，PDF 的模型 Undo 是一筆。直線本身在畫布的 `undoManager` 註冊一筆 Undo（還原成加線前的 `drawing`）：白板與筆畫共用那個堆疊；PDF 的畫布 `undoManager` 是私有的、照舊丟掉，由模型 Undo 負責。
  - 座標：畫布座標 = 觸控在 `PKCanvasView` 的位置 ÷ `zoomScale`（白板的畫布會縮放；PDF 的畫布不捲動、倍率 1）。
- **Mac**：沒有 PencilKit 書寫，白板工具列不顯示手寫工具（只有選取與插入工具）；PDF 維持右下角的按鈕。
