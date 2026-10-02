# Roadmap 與 Todo

每個 Phase 列出目標、工作項目與驗收測試。驗收測試全部通過才進入下一個 Phase。進度以本節勾選狀態為準。

## Phase 0 — Spike + Prototype（完成）

- [x] S1 CodeMirror 6 在 WKWebView：注音組字無吃字或重複（iOS + macOS）、切換筆記 < 50ms、1 萬行 md 打字不卡、磁碟上 md 與輸入完全一致
- [x] S2 PencilKit ⇄ Excalidraw：來回轉換後點數與壓力保留；輸出檔可在 excalidraw.com 開啟
- [x] SwiftUI 外殼（側邊欄、檔案樹、編輯區）讀寫本地 Vault

## Phase 1 — 本地筆記 MVP（完成）

- [x] Live Preview
- [x] FTS5 trigram 搜尋、反向連結、標籤
- [x] `[[` 自動完成、連結改名
- [x] 外部修改偵測（VaultWatcher）

## Phase 1.5 — 模組化重構

目標：核心只剩檔案、同步、索引與外掛註冊；Markdown 與 Ink 變成外掛，功能行為不變。

- [x] Core 新增 KindRegistry、EasyNotesUI 新增 `PluginRegistry` 與 `EasyNotesPlugin` 協定；`DocumentKinds.all` 改由 Registry 提供
- [x] 新增 EasyNotesUI target，把 `WebEditorHost` 從 App 搬入
- [x] 拆出 KindMarkdown（`MarkdownKind`、`MarkdownEditorView`、CM6 bundle）
- [x] 拆出 KindWhiteboard（`InkKind`、`ExcalidrawInk`、`PencilKitBridge`、`InkEditorView`）
- [x] `App/Editors/EditorRegistry.swift` 的 `switch` 改為向 Registry 查詢
- [x] `web/` 改為多 entry 打包，輸出到各外掛的 Resources
- [ ] Vault 根目錄建立 `CLAUDE.md`（Vault 慣例）
- [ ] 編輯器保留的 `EditorState` 改為 LRU（最近 20 篇），收到記憶體警告時清掉不在畫面上的
- [ ] 建立 Release build 的大小、記憶體、耗電基準線（見「非功能預算」）

2026-10-01：結構重構完成，進入 Phase 2。VaultWatcher 增量重掃移到 Phase 2（hash 與改名推斷的前置）；Vault 的 CLAUDE.md、EditorState LRU、Release 基準線延後到 Phase 2 之後，對應的驗收測試一併延後。

驗收測試：

- [ ] 各外掛的 `Package.swift` 只依賴 EasyNotesCore / EasyNotesUI；Core 的測試不 import 任何外掛
- [ ] 現有 `VaultIndexTests`、`InkRoundTripTests` 搬家後全部通過
- [ ] 新增 Registry 單元測試：未註冊的副檔名回傳 nil、重複註冊同一副檔名會報錯
- [ ] 手動：iPad 與 Mac 開啟 md、手寫檔，編輯、搜尋、反向連結行為與重構前相同
- [ ] Claude Code 一次修改 50 個檔案：只重新索引這 50 個（用 log 或測試驗證）
- [ ] 開過 30 篇筆記後，記憶體中只保留 20 個 `EditorState`
- [ ] 基準線符合非功能預算（大小、iPhone 閒置記憶體、Energy gauge）

## Phase 2 — 同步（含三方合併）

目標：Mac、iPad、iPhone 離線編輯後重新連線，內容收斂一致且不遺失；Claude Code 在 Mac 上的修改會同步到其他裝置。

- [x] VaultWatcher 只重掃事件帶來的路徑，不再每次對整個 Vault 做 stat
- [ ] Supabase Auth：Sign in with Apple 與登入流程
- [x] `files` 資料表、RLS、Storage bucket 政策（migration 納入 repo）
- [x] `commit_file` RPC：伺服器端版本檢查
- [x] 本地 `sync.sqlite`：file id ⇄ path、base version、上傳佇列
- [x] 內容定址上傳、Realtime 訂閱、前景補拉
- [x] 改名與搬移（App 內直接更新；外部改名以 hash 推斷）
- [x] Markdown diff3 三方合併 + 編輯中套用遠端變更（`applyRemote`）
- [x] Excalidraw 依元素 `id` + `version` 合併
- [ ] 衝突副本、軟刪除（30 天）
- [x] 同步狀態 UI（已同步 / 待上傳 / 衝突）
- [x] Realtime 只在前景連線；上傳佇列合併連續變更、批次上傳

驗收測試：

- [x] diff3 單元測試：不同段落各自修改 → 自動合併；同一行都改 → 衝突副本；中文、CRLF、檔尾無換行、frontmatter
- [x] Excalidraw 合併單元測試：兩邊各加筆畫 → 都保留；同一元素都改 → version 高者勝
- [x] RPC 併發測試：兩個 client 以同一 base version 上傳 → 一個成功、一個拿到 null 並進入合併
- [x] RLS 測試：用另一個帳號讀不到任何列與 Storage 物件
- [ ] 整合：Mac + iPad 同時離線編輯同一篇 → 連線後兩邊 hash 相同
- [ ] 整合：iPad 改名、Mac 同時編輯同一篇 → 改名與內容都保留
- [x] 整合：App 開著時用 Claude Code 修改、搬移檔案 → 數秒內出現在 iPad，file id 不變
- [x] 整合：上傳中強制結束 App → 重啟後自動補傳，無資料遺失
- [ ] 整合：刪除後 30 天內可還原
- [ ] 耗電：進背景後沒有網路連線；連續打字 1 分鐘只產生少數幾次上傳
- [ ] 基準線符合非功能預算（含 supabase-swift 後的 App 大小）

## Phase 2.5 — UI 重構

目標：外殼從 SwiftUI 預設樣式換成 `design/easy-notes-ui.pen` 的設計，資料模型與外掛邊界不變。

設計稿節點（2026-10-02 版）：

| 平台 | 畫面 | 節點 |
| --- | --- | --- |
| Desktop / iPad | 檔案列表（淺色 / 深色） | `RZ0Lk` / `xf8q7` |
| Desktop / iPad | 編輯器（淺色 / 深色，中文內容） | `zUTPY` / `xqIQO` |
| Desktop / iPad | 空 Vault、空資料夾 | `xGsaX`、`m4Bb4` |
| Mobile | 首頁、編輯器、Spaces | `CIaUn`、`sk74A`、`sulbD` |
| 元件 | 側邊欄（附說明 `c3JKt`）、Sidebar Item、Icon Button、Doc Card、Thumb CSV / Board / PDF、M Doc Row、M Pin Card、M Tab Bar、Format Bar | `YXFMc`、`WYNg6`、`QOPWl`、`KdLwJ`、`otUrV` / `r2BDR`（`Rr1po`）/ `CGJEp`、`i08TyX`、`xiCip`、`oPziA`、`n2KUAm` |

字型：Pen 不支援蘋果字型，設計稿以 Inter 代替（`font-ui`、`font-doc`、`font-cjk` 三個變數）。實作一律用系統字型：拉丁字 SF Pro、中文蘋方-繁（SwiftUI 預設字型；CM6 用 `-apple-system`），不打包 Inter。字級、字重、行高照設計稿。

設計稿與 EasyNotes 模型的對應：

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
| Review | Flashcards 外掛以 `addPanel` 註冊；Phase 3 前不顯示 |
| Recently Deleted（保留 30 天） | 現有「最近刪除」 |
| Synced · 2 min ago | 現有同步狀態（已同步 / 待上傳 / 衝突） |
| 資料夾圖示（`folder-open`） | 在 Finder 中顯示（iOS：在「檔案」App 中顯示） |
| Me（Mobile 分頁） | 帳號、同步面板、設定 |

### 2.5-0 設計稿待補

下列項目在 2026-10-02 版的 Pen 中仍是舊內容，實作前先改設計稿：

- [x] 編輯器 `zUTPY` / `xqIQO`：刪除協作者頭像（A、M）、留言、分享按鈕與作者「Rong」；⭐ 改為釘選；浮動工具列刪除 ✨；「12 個區塊」改字數；示範內文中「留言」的句子
- [x] `C/Sidebar Desktop`：Vault 標頭的切換箭頭；每列重複的 `24`（文件、最近刪除、設定）
- [x] Mobile 首頁 `CIaUn`：Vault 標頭、🔔、篩選 chips、「6 blocks」、文件數（28 → 與 Desktop 一致）
- [x] Mobile 編輯器 `sk74A`：作者、⭐、「blocks」；換成中文內容
- [x] Mobile Spaces `sulbD`：「Personal · Pro」、Starred → Pinned、Shared、「3 shared」、「daily」、Edit
- [x] `C/M Doc Row`「12 blocks」、`Format Bar` 的 ✨
- [x] 空 Vault `xGsaX` 的「Open Folder…」：Vault 位置已固定為 `~/Documents/EasyNotes`，改為「在 Finder 中顯示」或刪除
- [ ] 補畫：iPad 版面、⌘K 快速開啟、`[[` 自動完成、游標所在行顯示原始 md 的狀態、衝突提示、Me / 設定 / 同步面板、Sign in with Apple
- [x] Phase 3 畫面（`rHTaT`、`b2AjRQ`）：刪除 Share、columns、「Add Cards」、🔊、🚩（Phase 3 開工前處理即可）

### 2.5a 設計系統

- [x] Pen variables（含 `mode: light / dark` 兩組值）轉成 `EasyNotesUI` 的 `Theme` tokens：背景、文字、邊框、accent、surface、卡片狀態、圓角
- [x] 類型顏色由外掛提供：`registry.addKind(..., symbol:, tint:)`，App 與列表頁只讀 Registry
- [x] 同一組 tokens 輸出成 CM6 的 CSS variables（WebEditorHost 以 user script 注入，不經 Bridge），WebView 與原生顏色一致；跟隨系統深淺色切換
- [x] 字型：SwiftUI 用系統字型 + 設計稿字級；CM6 用 `-apple-system`，中文 fallback 蘋方-繁
- [x] 共用元件：Sidebar Item、Icon Button、Doc Card、Doc Row、Pin Card、Tab Bar、空狀態

2026-10-02：設計系統放在 `EasyNotesUI/DesignSystem/`（`Palette`、`KindTint`、`TextStyle`、`Metrics`、`ThemeCSS` 與共用元件），`DesignSystemGallery` 可在 Xcode Preview 或 `EASYNOTES_SNAPSHOT_DIR=… swift test` 輸出截圖比對設計稿。CSS variables 由 `ThemeCSS.stylesheet()` 產生，2.5d 起由 WebEditorHost 注入 CM6。

### 2.5b 外殼與導覽

- [x] Desktop / iPad 側邊欄：Vault 標頭、搜尋（⌘K）、All Documents、Recents、Pinned、Spaces（可展開的檔案樹，檔案用類型圖示）、Tags、Recently Deleted、同步狀態、Settings
- [x] PluginRegistry 新增 `addPanel`，讓外掛加側邊欄項目，App 不寫死 Review
- [x] ⌘K 快速開啟：取代目前側邊欄的 `.searchable`，重用 FTS5 搜尋與 `HitRow`
- [x] 工具列：上一頁 / 下一頁、麵包屑（資料夾 / 檔名）、網格 / 列表、排序、在 Finder 中顯示、New Document 選單
- [x] New Document 選單與快捷鍵：新筆記 ⌘N、新白板 ⇧⌘N、匯入 PDF、匯入 CSV、新資料夾，項目來自 `addNewFile` / `addImport`
- [x] iPhone：底部分頁（Docs / Search / Spaces / Me），取代 `NavigationSplitView` 的摺疊行為
- [x] ~~反向連結：保留 inspector，套用新樣式~~ → 2026-10-02 決定移除反向連結 inspector（索引仍保留反向連結資料）

2026-10-02：外殼改為 `Route`（所有文件 / 最近 / 釘選 / 資料夾 / 標籤 / 檔案 / 外掛面板）＋上一頁 / 下一頁歷史（⌘[ / ⌘]），App 啟動時顯示所有文件。列表頁目前是 2.5c 的骨架（標題 + 統計、子資料夾、網格 / 列表、依修改時間或名稱排序，縮圖用佔位）。補充決定：

- 介面語言統一為繁體中文：App 宣告 `zh-Hant` 在地化，系統選單（檔案、編輯、顯示方式、視窗、輔助說明）也是中文；側邊欄的 Spaces / Tags 顯示為「空間」「標籤」。
- ⌘K 給快速開啟，Markdown 的「[[連結]]」改為 ⇧⌘K；新資料夾 ⇧⌘F。
- 移除 Markdown 編輯器工具列上 Spike S1 的載入時間（benchmark）顯示。
- 側邊欄的「釘選」已有入口，但釘選資料要等下方待決事項（frontmatter 或 `pins.json`）決定後在 2.5c 接上，目前顯示空狀態。
- 匯入的目的地為目前所在的資料夾：資料夾頁 = 該資料夾、編輯器 = 文件所在的資料夾、其他列表頁 = Vault 根目錄（見 2.5d 待決事項）。

### 2.5c 文件列表

- [x] All Documents / 資料夾頁：標題 + 統計（文件數、資料夾數）、類型篩選、Pinned 區（Pin Card）、Recent 區（Desktop 網格、Mobile 列表）
- [x] 空狀態：空 Vault（`xGsaX`）、空資料夾（`m4Bb4`，顯示 Vault 內路徑，可拖入檔案）
- [x] 實作 `addPreview`（原生渲染，不開 WebView）：Markdown = 標題 + 前幾行；CSV / 白板 / PDF 先用 Thumb 元件的佔位樣式，各外掛完成後再換成真實縮圖
- [x] 卡片副標：外掛提供一行摘要（字數、列數、頁數）＋相對時間
- [x] 預覽快取：依 hash 存在 `.easynotes/cache/preview/`，檔案未變就不重算
- [x] 索引補欄位：frontmatter 的 `icon`、`pinned`、字數（`IndexEntry` 新增欄位，Core 只存不解讀）

2026-10-02 實作決定：

- 釘選存 frontmatter `pinned: true`（見待決事項）。`DocumentKind.setPinned(_:in:)` 預設回傳 nil = 不支援，列表的「釘選」選單只對支援的類型顯示。App 寫入後把 mtime 還原，釘選不會讓文件跑到「最近」最上面。白板之後改存 `customData`，PDF 等外掛完成再處理。
- `IndexEntry` 新增 `icon`、`pinned`、`summary`（外掛提供的一行摘要，例如「1,240 字」「32 筆畫」），Core 不認識「字數」；索引另存內容 `hash` 作為預覽快取的 key。
- `addKind(..., name:)` 提供篩選 chip 的名稱（筆記、白板），App 不寫死。
- Mobile 的篩選與 Desktop 相同（全部 + 已註冊的類型）；Pen 的 Mobile 首頁 chips 與 `C/M Doc Row` 的「blocks」一併改掉。
- 封面（frontmatter `cover`）的卡片縮圖留到 2.5d。
- 預覽協定命名為 `DocumentPreviewProvider`（避開 SwiftUI 的 `PreviewProvider`）。
- 列表的文件與資料夾有 hover 狀態（卡片加深邊框並浮起、列加 `bg-hover`、游標變手指；iPad 指標用系統 highlight）。
- 釘選會替原本沒有 frontmatter 的 md 加上 frontmatter，所以 CM6 先做最小的處理：游標不在區塊內時收合成一行屬性（📌 已釘選、icon、標籤），點一下才顯示 YAML；2.5d 換成完整的文件頭。

### 2.5d 編輯器

- [x] Markdown 文件頭：frontmatter 在 CM6 以 block widget 顯示為封面、icon、標題、meta（標籤、最後編輯時間），游標進入時才顯示原始 YAML
- [x] 更換封面 / icon：寫回 frontmatter（經 Vault，走一般的寫檔與同步路徑）
- [x] 封面圖片由 `WKURLSchemeHandler` 從 Vault 讀取
- [x] Live Preview 樣式對齊設計稿：callout（`> [!tip]`）、核取清單、引言、`[[連結]]` 獨占一行時顯示為連結卡片（含目標檔案的類型圖示）
- [x] 浮動格式工具列（Desktop 右下）與 iOS 鍵盤工具列（`Format Bar`）：原生 SwiftUI，按下時送 `exec`，不在打字路徑上
- [x] 工具列：麵包屑、同步狀態、釘選、更多選單（在 Finder 中顯示、複製路徑、用其他 App 開啟）
- [x] Mobile 編輯器：返回所在資料夾、同步狀態、釘選、分享（系統 Share Sheet 分享檔案）、更多

2026-10-02 實作決定（開工前）：

- 設計稿重新對齊 2.5-0：刪除 Presence、分享、✨；連結卡片副標改用外掛摘要（「320 個字」「CSV · 24 列」）；meta 列只有標籤 + 「N 分鐘前編輯」（不顯示閱讀時間）；工具列右側為釘選 + 更多；Mobile 編輯器 `sk74A` 改為中文內容。
- 文件頭是 CM6 decorations：封面 + icon 為檔案開頭的 block widget；標題就是第一行 `# `（一般文字，組字不受影響，索引規則不變）；meta 列為標題行之後的 block widget。游標進入 frontmatter 才顯示原始 YAML。
- 封面存 frontmatter `cover: 附件/xxx.jpg`（Vault 內路徑）；從 Vault 外選的圖片複製到 Vault 根目錄的 `附件/`，重名加序號。更換封面 / icon 走一般寫檔路徑（會更新 mtime、進同步），與釘選不同。
- 圖片經 `vault://<相對路徑>`（`WKURLSchemeHandler`，在 EasyNotesUI 的 WebEditorHost）讀取，只允許 Vault 內路徑。
- 主題：`ThemeCSS.stylesheet()` 以 user script 在頁面載入前注入，WebView 自己跟隨系統深淺色，不經 Bridge。類型顏色不進全域 CSS，由連結目標資料帶入。
- 連結卡片需要目標的類型、摘要、時間：`EditorController.linkTargetsChanged` 改傳 `LinkTarget`（名稱、kind、摘要、mtime、tint、圖示 PNG）。WebView 沒有 SF Symbols，圖示由 Swift 依 Registry 的 symbol 畫成 PNG。
- 文件 icon 支援 Emoji 與 SF Symbols（不打包 Lucide）：frontmatter `icon: 🗺` 或 `icon: sf:map`，Core 只存字串。選單為「圖示 | 表情符號」；Apple 沒有列出所有 SF Symbols 的 API，所以內建常用清單，搜尋框也接受完整名稱。名稱不存在時顯示類型的預設圖示。列表卡片：emoji 接在標題前、SF Symbol 取代類型圖示；編輯器文件頭經 `symbol:///<名稱>`（`WKURLSchemeHandler`）顯示。在 App 外（例如 Obsidian）只會看到 `sf:` 文字。
- 浮動格式工具列與 iOS Format Bar 共用 `FormatBar`（T 選單、核取清單、插入圖片、插入表格）；編輯器工具列（儲存狀態、釘選、更多）放在 App，所有檔案類型共用。

待決事項：

- [x] 字型 → 實作用系統字型（SF Pro + 蘋方-繁），Pen 的 Inter 只是替代
- [x] 釘選存 frontmatter 會改動檔案（mtime、同步）；若不想讓釘選觸發同步，改存 `.easynotes/pins.json`（需要集合型合併）→ 2026-10-02 決定存 frontmatter：Claude Code 可直接讀寫、`.easynotes/` 不必加入同步；寫入後還原 mtime
- [x] 設計稿的「關聯頁面」是內文還是自動產生的區塊？→ 2026-10-02 決定當作內文樣式：`[[連結]]` 獨占一行顯示為連結卡片，相鄰的多行並排；反向連結 inspector 已移除
- [x] 匯入 PDF / CSV 的目的地：目前所在資料夾，或固定的 `Inbox/`？→ 2026-10-02 決定用目前所在的資料夾，不另設 `Inbox/`

驗收測試：

- [ ] App target 沒有寫死任何檔案類型或外掛名稱（側邊欄項目、篩選、類型顏色、預覽、新增選單都來自 Registry）
- [x] 只註冊 Markdown 與白板時，篩選只出現 Notes / Boards，新增選單沒有匯入 PDF / CSV
- [x] 刪掉 `.easynotes/cache/preview/` 後重新產生，畫面相同
- [x] Claude Code 修改 frontmatter 的 `icon`、`pinned` → 數秒內反映在列表與側邊欄
- [ ] 更換封面 / icon 後，md 只多出 frontmatter 欄位，其餘內容逐位元組相同
- [ ] 注音輸入：在文件頭附近、callout、核取清單內組字正常
- [ ] 切換筆記仍 < 50 ms；文件列表 1,000 篇捲動流暢（預覽不在主執行緒產生）
- [ ] 手動：Mac、iPad、iPhone 截圖與 Pen 設計稿並排比對，淺色 / 深色都檢查（字型差異除外）

## Phase 3 — Flashcards

目標：在 md 內寫卡片，用與 Anki 相同的 FSRS 排程複習；多裝置紀錄自動合併。

2026-10-02 決定（設計見 Architecture「Flashcards」）：排程用 swift-fsrs 的 FSRS-6（以 `revision:` 固定 commit，明確傳入 21 個參數），優化用 fsrs-rs；資料夾 = 牌組、標籤 = 篩選學習；設定以 preset 管理（`.easynotes/srs/config.json`），預設值與 Anki 相同；重播時到期日採用紀錄的 `ivl`，只重算記憶狀態。

分四個子階段，依序進行；每個子階段的驗收測試通過才進入下一個。3a、3b 不需要介面，全部可用單元測試驗證；3c 完成後即可日常使用；3d 是互通與優化。

### 3a 卡片解析與語法標示

目標：md 中的卡片能被解析、建立索引，並在編輯器中標示出來；還不能複習。

- [ ] 新增 `Flashcards` 外掛 package（只依賴 EasyNotesCore / EasyNotesUI），在 App 註冊
- [ ] 卡片解析（`::`、`;;`、`{{}}`、`^id`）；卡片 id 後綴（`:r` 反向、`:n` 克漏字）；程式碼區塊與 frontmatter 內不解析
- [ ] 缺 `^id` 時自動補上（經 Vault 的一般寫檔路徑）；重複 `^id` 只改後出現的那一行
- [ ] `addIndexContributor`：索引卡片（note id、卡片 id、類型、所在檔案與行、正反面文字）
- [ ] Markdown 外掛的卡片語法標示（CM6 decorations；`^id` 淡化顯示）
- [ ] Vault 的 `CLAUDE.md` 寫入卡片語法規格

驗收測試：

- [ ] 解析器 fixture 測試：三種語法、程式碼區塊與 frontmatter 內不視為卡片、編輯卡片文字後 `^id` 不變、重複 `^id` 只改後出現的
- [ ] Claude Code 寫入 50 行 `::` 卡片 → 數秒內全部補上 `^id`，其餘內容逐位元組相同
- [ ] 注音輸入：在卡片行內組字正常，`^id` 不在組字中被補上（只在存檔路徑）

### 3b 排程、紀錄與重播

目標：卡片狀態可由紀錄重播得出，排程結果與 Anki 一致。

- [ ] 接入 swift-fsrs（`revision:` 固定 commit、FSRS-6 預設參數）
- [ ] 卡片狀態（New / Learning / Review / Relearning）、learning 與 relearning steps、四鍵、desired retention 對齊 Anki
- [ ] 複習紀錄 `.easynotes/srs/<deviceId>.jsonl`（欄位對齊 Anki revlog）
- [ ] 重播：合併所有裝置的紀錄 → 卡片狀態；到期日採用紀錄的 `ivl`，記憶狀態用目前參數重算；結果快取在可重建的索引
- [ ] 暫停 / 恢復 / 重設寫成紀錄事件

驗收測試：

- [ ] 排程結果與 fsrs-rs / py-fsrs 參考向量一致（FSRS-6 預設參數與自訂 `w`）
- [ ] 重播決定性：同一組紀錄在不同裝置算出相同卡片狀態；換參數後到期日不變、記憶狀態重算
- [ ] 整行搬到別篇筆記後，重播出的狀態與歷史不變
- [ ] 刪掉索引後重建，卡片狀態相同

### 3c 牌組、設定與複習介面

目標：可以日常使用的複習流程。

- [ ] 牌組樹（資料夾階層）與各牌組的到期數 / 新卡數；標籤篩選學習
- [ ] Preset 設定與 `config.json`（資料夾繼承上層、改名時更新路徑、欄位 LWW 合併）
- [ ] 每日上限（母牌組涵蓋子牌組）、新卡順序、複習排序、埋藏 sibling、Leech、新的一天開始時間
- [ ] 原生複習介面：`addPanel` 的「複習」（badge 為到期數）、牌組列表、卡片正反面、四鍵與下次間隔、鍵盤快捷鍵（Mac / iPad）
- [ ] 設定畫面：preset 編輯、牌組指定 preset、全域設定
- [ ] 設計稿：Phase 3 畫面（`rHTaT`、`b2AjRQ`）補上牌組樹與設定畫面

驗收測試：

- [ ] 每日上限：母牌組上限涵蓋子牌組；同一行的 sibling 依設定埋藏
- [ ] `config.json` 合併：兩台裝置改不同欄位 → 都保留；資料夾改名後 preset 仍套用
- [ ] 多裝置：Mac 與 iPad 各自複習後同步，到期日正確
- [ ] 手動：Mac、iPad、iPhone 完成一輪複習，畫面與設計稿比對（淺色 / 深色）

### 3d 互通與參數優化

目標：與 Anki 互通，並用自己的紀錄優化參數。

- [ ] TSV 匯出給 Anki
- [ ] fsrs-rs 參數優化（UniFFI、XCFramework）；紀錄不足時不允許；結果寫回 preset 的 `w`
- [ ] 量測加入 fsrs-rs 後的 App 大小（非功能預算）
- [ ] 選做：匯入 Anki `.apkg` 與複習歷史

驗收測試：

- [ ] 手動：TSV 匯入 Anki 後卡片正確
- [ ] 同一組紀錄，App 內的優化結果與 Anki 的優化結果相近
- [ ] 基準線符合非功能預算

## Phase 4 — Whiteboard

目標：用原生白板取代 Excalidraw，檔案仍是標準 `.excalidraw`。

- [ ] 結構層：rectangle、ellipse、arrow（綁定）、text、image、frame
- [ ] 選取、移動、縮放、刪除、undo
- [ ] 手寫層與結構層的手勢分工（Pencil 畫、手指移動）
- [ ] md 內 `![[x.excalidraw]]` 嵌入預覽（SVG 快取）
- [ ] 選做：筆記卡片元素（見外掛功能設計）

驗收測試：

- [ ] 序列化測試：6 種元素來回不變；未知元素與欄位原樣保留
- [ ] 手動：輸出檔在 excalidraw.com 開啟、箭頭仍綁在形狀上
- [ ] 移動形狀後綁定的箭頭跟著走
- [ ] 1,000 個元素的畫布縮放與平移仍流暢（iPad）

## Phase 5 — PDF 手寫與標註

目標：在上課 PDF 上用基本工具手寫，原始 PDF 不被修改。

- [ ] `PDFView` + `PDFPageOverlayViewProvider`，可見頁面才建立 `PKCanvasView`
- [ ] 工具：原子筆、螢光筆、橡皮擦、套索選取、便利貼
- [ ] `.pdf.ink` 旁檔讀寫、檔案樹中隱藏、依頁 + 元素合併
- [ ] 匯出合併標註的 PDF

驗收測試：

- [ ] 縮放、捲動後筆畫位置正確；關閉重開後完整還原
- [ ] 200 頁 PDF 快速捲動，記憶體穩定（Instruments 觀察）
- [ ] 標註前後原始 PDF 的 hash 不變
- [ ] 手動：匯出的 PDF 在「預覽程式」中正確顯示筆畫與便利貼

## Phase 6 — Sheets

目標：用 RevoGrid 編輯 CSV，不影響其他工具讀取。

- [ ] Swift 端 RFC 4180 解析與序列化
- [ ] RevoGrid 編輯器（WebView，共用 WebEditorHost）
- [ ] RevoGrid WebView 開檔時才建立、關閉後釋放
- [ ] `.csv.meta.json`（欄寬、凍結欄）
- [ ] 以列為單位的 diff3 合併
- [ ] md 內 `![[x.csv]]` 嵌入預覽

驗收測試：

- [ ] 未修改的 CSV 寫回後逐位元組相同
- [ ] 含引號、逗號、換行、中文的欄位來回不變
- [ ] 儲存格內注音輸入正常
- [ ] 1 萬列捲動流暢n

## 風險與待決事項

| 風險 | 影響 | 緩解 |
| --- | --- | --- |
| 同步資料遺失 | 信任崩潰 | 內容定址 Storage 只增不覆寫、伺服器端版本檢查、diff3 合併、衝突副本、軟刪除 |
| 外部工具改名被視為刪除 + 新增 | 失去歷史與合併基準 | 以 hash 推斷改名；最差情況只失去歷史，不遺失內容 |
| 外掛介面設計過早 | 後續外掛被錯誤的抽象綁住 | Markdown 先走外掛介面；擴充點等第二個外掛需要時才抽出 |
| WebView 記憶體 | iPhone 後台被殺 | 單一共用 WebView，多分頁共用一個 process pool |
| PDF 大檔記憶體 | 閃退 | 只為可見頁面建立 `PKCanvasView`，離開畫面就回收 |
| `PKCanvasView` 只支援 iOS | macOS 無法手寫 | 接受：macOS 只顯示手寫，結構元素仍可編輯 |
| swift-fsrs 版本落後 | 排程與 Anki 不一致 | 以 fsrs-rs 參考向量做回歸測試；必要時改用 fsrs-rs 的 UniFFI 綁定做排程 |
| 套件授權 | 個人使用影響很小 | 仍優先選 MIT / BSD：RevoGrid（MIT）、fsrs-rs（BSD-3） |

待決事項：

- [x] macOS 上 vault 要放使用者可見的資料夾（可用 Finder / 其他編輯器開），還是 App 沙盒內？
- [x] Sheets 是否需要公式？→ 不需要。CSV 只存資料，需要公式時用外部 App 開啟。
- [x] 是否需要 Android / Web 版？→ 不需要。個人使用，只支援 Apple 平台。

Vault 位置已決定：macOS 用可見資料夾 `~/Documents/EasyNotes`，不開沙盒。
