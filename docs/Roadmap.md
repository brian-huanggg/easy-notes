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
- [x] Vault 根目錄建立 `CLAUDE.md`（Vault 慣例）→ 2026-10-02 於 3a 完成（`addVaultGuide`）
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
- 文件頭是 CM6 decorations：封面 + icon 為檔案開頭的 block widget；標題就是第一行 `#`（一般文字，組字不受影響，索引規則不變）；meta 列為標題行之後的 block widget。游標進入 frontmatter 才顯示原始 YAML。
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

2026-10-02 決定（設計見 Architecture「Flashcards」）：排程用 swift-fsrs 的 FSRS-6（以 `revision:` 固定 commit，明確傳入 21 個參數），優化用 fsrs-rs；資料夾 = 牌組、標籤 = 篩選學習；設定以 preset 管理（`.easynotes/srs/<deviceId>.config.json`，3c 改為各裝置各寫），預設值與 Anki 相同；重播時到期日採用紀錄的 `ivl`，只重算記憶狀態。

分四個子階段，依序進行；每個子階段的驗收測試通過才進入下一個。3a、3b 不需要介面，全部可用單元測試驗證；3c 完成後即可日常使用；3d 是互通與優化。

### 3a 卡片解析與語法標示

目標：md 中的卡片能被解析、建立索引，並在編輯器中標示出來；還不能複習。

- [x] 新增 `Flashcards` 外掛 package（只依賴 EasyNotesCore / EasyNotesUI），在 App 註冊
- [x] 卡片解析（`::`、`;;`、`{{}}`、`^id`）；卡片 id 後綴（`:r` 反向、`:n` 克漏字）；程式碼區塊與 frontmatter 內不解析
- [x] 缺 `^id` 時自動補上（`ContentFixer`；id 由路徑 + 行內容的 hash 決定；開啟中的檔案離開後才補）；重複 `^id` 只改後出現的那一行
- [x] Core 新增 `IndexContributor`（通用 `records` 表）與 `ContentFixer`；PluginRegistry 新增 `addIndexContributor`、`addContentFixer`、`addVaultGuide`
- [x] 索引卡片（note id、類型、所在行、正反面文字）
- [x] Markdown 外掛的卡片語法標示（CM6 decorations：非游標行 `::` / `;;` 顯示為箭頭、克漏字隱藏括號並標示、`^id` 隱藏；游標行顯示原始語法，`^id` 淡化）
- [x] Vault 的 `CLAUDE.md` 寫入卡片語法規格

驗收測試：

- [x] 解析器 fixture 測試：三種語法、程式碼區塊與 frontmatter 內不視為卡片、編輯卡片文字後 `^id` 不變、重複 `^id` 只改後出現的
- [x] 兩台裝置替同一行補 `^id` 得到相同結果，diff3 合併不衝突
- [ ] Claude Code 寫入 50 行 `::` 卡片 → 數秒內全部補上 `^id`，其餘內容逐位元組相同
- [ ] 注音輸入：在卡片行內組字正常；開啟中的檔案不會被補 `^id`，切到別篇後才補上

2026-10-02：3a 程式完成，單元測試通過（Core 的 `IndexContributorTests`、Flashcards 的 `CardSyntaxTests` / `CardIDsTests` / `CardIndexTests`，後者以 App 相同的流程模擬 50 張卡片補 id）。Vault 的 `CLAUDE.md` 由 Markdown 與 Flashcards 外掛各提供一節，App 加上 Vault 慣例的開頭。尚未在實機驗證：語法標示的外觀、注音組字、FSEvents 觸發後數秒內補上 id。

### 3b 排程、紀錄與重播

目標：卡片狀態可由紀錄重播得出，排程結果與 Anki 一致。

- [x] Core：`VaultFS.deviceID()`（`.easynotes/device-id`，不同步；SyncEngine 改用它，沿用 `sync.sqlite` 中原本的 id）
- [x] Core：`addSyncedMetaFolder`，SyncEngine 同步 `.easynotes/` 下註冊的子資料夾（Flashcards 註冊 `srs`）
- [x] 接入 swift-fsrs（`revision:` 固定 commit、FSRS-6 預設參數）
- [x] 卡片狀態（New / Learning / Review / Relearning）、learning 與 relearning steps、四鍵、desired retention 對齊 Anki
- [x] 複習紀錄 `.easynotes/srs/<deviceId>.jsonl`（欄位對齊 Anki revlog）
- [x] 重播：合併所有裝置的紀錄 → 卡片狀態；到期日採用紀錄的 `ivl`，記憶狀態用目前參數重算；結果放在記憶體（可隨時重播，量測後再決定是否存到 `.easynotes/cache/srs/`）
- [x] 暫停 / 恢復 / 重設寫成紀錄事件

驗收測試：

- [x] 排程結果與 fsrs-rs / py-fsrs 參考向量一致（FSRS-6 預設參數與自訂 `w`）
- [x] 重播決定性：同一組紀錄在不同裝置算出相同卡片狀態；換參數後到期日不變、記憶狀態重算
- [x] 整行搬到別篇筆記後，重播出的狀態與歷史不變
- [x] 刪掉索引後重建，卡片狀態相同
- [x] 換日時間：凌晨 4 點前後的複習分屬不同天；台灣時間早上 8 點（UTC 午夜）前後屬於同一天
- [x] 同步：`.easynotes/srs/*.jsonl` 在兩台裝置間同步；`.easynotes/cache/`、`device-id` 不上傳（假 backend 單元測試）

2026-10-02 開工前決定（設計見 Architecture「複習紀錄與重播」與「擴充點」）：紀錄欄位對齊 Anki revlog，另加 `op`（`suspend` / `unsuspend` / `reset`）；`.easynotes/srs/` 以外掛註冊的白名單參與同步；deviceId 由 Core 的 `.easynotes/device-id` 提供；swift-fsrs 固定在 `4fbaf20`（2026-05-25），以 UTC 換日，包裝層平移時間對齊 Anki 的換日時間；參考向量由 `scripts/` 的 Python 腳本（fsrs-rs-python、py-fsrs）產生成 JSON fixture。

2026-10-02：3b 程式完成，單元測試通過（Core 的 `SyncMetaFolderTests`；Flashcards 的 `FSRSVectorTests`、`ReplayTests`）。實作中的補充決定（見 Architecture「複習紀錄與重播」）：learning / relearning steps 依 Anki 的規則由包裝層處理（swift-fsrs 在第二步以後按 Hard 的行為與 Anki 不同）；py-fsrs 的向量另外套上 Anki 的 Hard ≤ Good < Easy 限制再比對；重播時記憶狀態一律走 swift-fsrs 的 learning 路徑以避開它對複習卡的四重計算（10 萬筆 release 約 1.3 秒），結果先只放記憶體。尚未接上 App：作答、背景重播、其他裝置紀錄變動時重新重播都在 3c 與複習介面一起做。

### 3c 牌組、設定與複習介面

目標：可以日常使用的複習流程。

- [x] 牌組樹（資料夾階層）與各牌組的到期數 / 新卡數；標籤篩選學習
- [x] Preset 設定與 `<deviceId>.config.json`（資料夾繼承上層、改名時更新路徑、欄位 LWW 合併）
- [x] 每日上限（母牌組涵蓋子牌組）、新卡順序、複習排序、埋藏 sibling、Leech、新的一天開始時間
- [x] 原生複習介面：`addPanel` 的「複習」（badge 為到期數）、牌組列表、卡片正反面、四鍵與下次間隔、鍵盤快捷鍵（Mac / iPad）
- [x] 設定畫面：preset 編輯、牌組指定 preset、全域設定
- [x] 復原上一次作答（刪掉本機紀錄檔的最後一行）、標籤篩選學習、Leech 虛擬標籤
- [x] 擴充點：`DocumentSession` 的 `vault` / `index` / `open(path, line:)` / `metaChanged()`；`EditorController` 的 `vaultChanged` / `moved` / `reveal`；`VaultIndex.fileTags()`
- [x] 設計稿：Phase 3 畫面（`rHTaT`、`b2AjRQ`）補上牌組樹與設定畫面

驗收測試：

- [x] 每日上限：母牌組上限涵蓋子牌組；同一行的 sibling 依設定埋藏
- [ ] 復原：作答後按 U，紀錄檔回到作答前、卡片狀態回到作答前
- [x] 設定合併：兩台裝置改不同欄位 → 都保留；資料夾改名後 preset 仍套用
- [ ] 多裝置：Mac 與 iPad 各自複習後同步，到期日正確
- [ ] 手動：Mac、iPad、iPhone 完成一輪複習，畫面與設計稿比對（淺色 / 深色）

2026-10-02：3c 程式完成，macOS 與 iOS Simulator 建置成功，單元測試通過（Flashcards 的 `SettingsTests`、`StudyTests`、`UndoTests`；Core 的 `fileTags`）。尚未驗證：復原的卡片狀態回復只測了紀錄檔層（`ReviewStore` 沒有單元測試）、多裝置同步、實機畫面與設計稿比對（含淺色、iPhone 版面）、「編輯筆記」捲到該行。

2026-10-02 設計稿（深色）：

| 畫面 | 節點 | 內容 |
| --- | --- | --- |
| 牌組列表 | `rHTaT` | 牌組樹（`C/Deck Row` `MKsOj` 加上縮排、展開箭頭、選項按鈕）；母牌組數字已套用上限（日文 new 30 < 子牌組 24 + 12）；Vault 根目錄的筆記顯示為「未分類」；篩選 chip「Filter by tag」= 標籤篩選學習；工具列右側為設定 |
| 複習 | `b2AjRQ` | 卡片只顯示正反面、來源檔案與行號、標籤、lapses |
| 牌組選項 | `AYlad` | Sheet：preset 選單（繼承上層 / 切換 / 新增 / 複製 / 重新命名 / 刪除）、preset 的所有欄位（兩欄）、全域設定（換日時間、按鈕顯示間隔、最佳化提醒）；「最佳化…」在 3d 前為停用狀態 |

2026-10-02 開工前決定（設計見 Architecture「設定」「每日上限與佇列」「複習介面」）：統計區塊移出 3c；設定改為每台裝置各寫 `<deviceId>.config.json`，讀取時欄位 LWW 合成（避免單一檔案在同步時變成衝突副本）；復原 = 刪掉本機紀錄檔的最後一行；Leech 的「加標籤」是由 lapses 算出的虛擬標籤，不改 md；標籤篩選不受每日上限限制；Flashcards 以 `EditorController` 接收 Vault 變動通知。

刪除：Share、Add Cards、columns 切換、排序按鈕（牌組依資料夾順序）、Suspended / Leeches chips（3c 沒有卡片瀏覽器；Leech 以標籤處理，可用標籤篩選）、「Open statistics」與所有統計區塊（連續天數、retention、到期預測圖、複習熱力圖、牌組列的 7 天預測；統計不在範圍內，今日橫幅只留進度環與剩餘張數）、複習卡片的例句框與提示行（一行語法沒有這些欄位）。新增文字以繁體中文撰寫，原有的英文介面文字尚未翻譯。

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

2026-10-02 決定（設計見 Architecture「Whiteboard」與「擴充點」）：維持原生、不用 Excalidraw Web runtime；結構層用 `CAShapeLayer` / `CATextLayer`（不用 SwiftUI Canvas），放在 `PKCanvasView` 底下；編輯器中手寫疊在圖形之上，存檔保留檔案順序；可顯示所有標準元素、可建立 6 種；依 fractional `index` 排序；箭頭綁定含 `fixedPoint`；圖片縮到 2048px 後內嵌 `dataURL`；Core 的 `DocumentPreview` 新增 `image`；WebEditorHost 新增 `embed://`。

分 Spike 與四個子階段，依序進行：S3 先驗證最有風險的畫布架構；4a 不需要介面，全部可用單元測試驗證；4b 完成後白板可在縮圖、嵌入與 Mac 檢視；4c 完成後可日常使用；4d 選做。

### S3 Spike：畫布架構（iPad 實機）

目標：在寫正式程式前，確認「layer 結構層 + `PKCanvasView` 手寫層」的組合可行。不通過就先改 Architecture 的設計再進 4c。

- [x] 原型（外掛內的 `Spike/CanvasSpike.swift`，側邊欄「畫布 Spike」面板）：`PKCanvasView` 底下一個 layer 結構層，畫 1,000 個隨機矩形 / 橢圓 / 箭頭 / 文字
- [x] 結構層跟著 `PKCanvasView` 的 `contentOffset` / `zoomScale` 移動；縮放結束時重設 `contentsScale`
- [x] 手勢分工：Pencil 畫圖、手指捲動縮放、手指點選圖形（hit test）並拖曳
- [ ] 選取工具時 Pencil 也能選取與拖曳（切換 `drawingPolicy` 或停用 `drawingGestureRecognizer`）
- [x] 視窗裁切：只為畫面內（加一圈緩衝）的元素建立 layer

驗收測試（iPad 實機，Release build）：

- [x] 1,000 個元素時平移、縮放維持 ProMotion 下 ≥ 60 fps（Instruments Animation Hitches 無明顯卡頓）
- [x] 縮放到 4× 後線條與文字清晰（不是點陣放大）
- [x] 手寫筆畫與結構層在平移、縮放中始終對齊（無位移、無延遲一幀）
- [x] 手指捲動時不會畫出筆畫；Pencil 書寫延遲與現有手寫畫面相同
- [x] 記錄結論與數據到本節，必要時修改 Architecture「Whiteboard」

2026-10-02：原型完成，macOS 與 iOS Simulator 建置成功，尚未在 iPad 實機量測。用法：

- 面板只在 DEBUG 或啟動參數 `-WhiteboardSpike YES` 時出現（Xcode：Edit Scheme → Run → Arguments；Build Configuration 改 Release 量測幀率）。不讀寫 Vault。
- 左上 HUD：FPS、一秒內最長的一幀、目前的 layer 數 / 元素數、縮放倍率、點陣倍率、選取的元素。
- 工具列：筆（Pencil 書寫、手指捲動縮放、手指拖曳元素）/ 選取（Pencil 與手指都拖曳元素）；選項選單可切換元素數（100 / 1,000 / 3,000 / 10,000）、視窗裁切、縮放後重設 `contentsScale`，用來 A/B 比較。
- 元素分布固定（固定種子），每次結果可比較。

2026-10-02 第一輪實機結果：

| 項目 | 結果 |
| --- | --- |
| 100–3,000 個元素 | 61 FPS，最長一幀 22.5 ms（待確認機型是否 ProMotion、是否開低耗電模式；ProMotion 應接近 120） |
| 10,000 個元素 | 30 FPS（超出目標 1,000；縮小時全部 layer 都在畫面內） |
| 4× 清晰度 | 清晰（縮放後重設 `contentsScale` 有效） |
| 快速縮放 | 每個元素的殘影閃現又消失 |
| 手指捲動 | 不會誤畫筆畫，但會誤抓到圖形 |

第一輪後的修改（待第二輪驗證）：

- 殘影：推測是點陣倍率只在縮放結束才更新，從 4× 快速縮小時舊 layer 與途中新建的 layer 都以 8 倍像素點陣化，上千個同時在畫面內撐爆記憶體。改為縮小途中倍率降到一半以下就立即降低點陣倍率，放大仍等結束；點陣倍率 = 縮放倍率（0.25…4）。
- 誤抓圖形：筆模式下手指以捲動為主，點一下 = 選取（空白處取消選取），長按 0.35 秒才拖曳圖形；選取模式維持碰到就拖曳。
- HUD 改為每秒更新一次（原本每一幀觸發 SwiftUI 重繪，會干擾量測）。
- 10,000 個元素：不在 S3 目標內。正式版的做法（4c）：縮放倍率低且畫面內 layer 超過門檻時，改畫一張點陣快照（LOD），停止縮放後再換回個別 layer。

2026-10-02 第二輪實機結果（iPad Air M1，60Hz、無低耗電模式）：

- FPS 約 60 = 該機型上限，符合目標；ProMotion 機型之後有機會再量。
- 筆模式手勢符合預期：手指捲動不會抓到圖形，長按才拖曳。
- 殘影只剩文字，圖形沒有；關閉「縮放後重設 contentsScale」就消失（但 4× 變模糊）。原因：`CAShapeLayer` 是向量、在渲染程序繪製；`CATextLayer` 是點陣 `contents`，改 `contentsScale` 後的重畫發生在下一個 display 週期，不在關閉動畫的 transaction 內，預設 0.25 秒淡入淡出，舊點陣以新倍率顯示 → 放大時出現縮小的殘影、縮小時出現放大的殘影。修正：文字 layer 關閉 `contents` 動作，並在同一個 transaction 內 `displayIfNeeded()`（第三輪確認殘影消失）。

2026-10-02 第三輪實機結果：文字殘影消失；筆畫與圖形在平移、縮放中對齊；Pencil 延遲與現有手寫畫面相同。新問題：手指**縮小**畫布時，所有筆刷的筆畫都會先出現一個更小的狀態，再回彈到正確尺寸；放大沒有。筆畫完全由 `PKCanvasView` 繪製，結構層沒有改它的縮放，所以先 A/B 判斷來源：選項新增「隱藏結構層（只剩 PencilKit）」（移除結構層、停止同步與手勢），並與現有手寫畫面（`InkEditorView`，純 `PKCanvasView`）比較。

2026-10-02 A/B 結果：開著結構層才有回彈，隱藏結構層（只剩 PencilKit）沒有 → 是結構層造成的。推測原因是縮放 callback 中的主執行緒工作讓那一幀延遲，PencilKit 的點陣與 scroll view 的 transform 短暫對不上：(1) 縮小途中降低點陣倍率時，同步重畫所有文字（第一輪為了殘影加入；後來證實殘影來自 `contents` 淡入淡出，不需要這一步）；(2) 縮小時可見範圍變大，同一個 callback 一次建立大量 layer。修改（待第四輪驗證）：

- 縮放中不再重新點陣化既有的 layer；新建的 layer 用 min(目前倍率, 縮放倍率)。縮放結束後才排入佇列重新點陣化。
- 建立 layer 與重新點陣化都分批：每幀最多 120 個，剩下的由 display link 在之後的幀處理（關閉裁切時仍一次建完，供比較）。
- HUD 新增「callback 最長」（一秒內 scroll / zoom callback 與分批工作的最長主執行緒時間）與「待處理」數量。

2026-10-02 修正判斷：回彈的真正原因是**縮放回彈**（rubber band），不是主執行緒。手指縮到最小值 0.25 以下時，scroll view 讓內容跟著縮得更小，放手後以 Core Animation 動畫彈回 0.25；動畫期間不會每幀呼叫 `scrollViewDidZoom`，所以結構層直接跳到 0.25，筆畫還在動畫中 → 看起來筆畫縮小又回彈。隱藏結構層時筆畫同樣回彈，只是沒有對照物，看起來是正常手感，與 A/B 結果一致；最大值 4× 以上同理。處理：`bouncesZoom = false`（選項「縮放回彈」，預設關閉），不去追 PencilKit 私有的縮放 view。上一段的分批與不在縮放中重新點陣化仍保留，作為避免主執行緒卡頓的做法（待第五輪驗證）。

2026-10-02 第五輪：關閉縮放回彈後筆畫不再回彈，確認原因。已驗證的結論寫入 Architecture「Whiteboard」。

### 4a 模型與序列化

目標：元素模型、綁定與連結都能以單元測試驗證；還沒有介面。

- [x] 修正：Whiteboard 註冊 `EditorController`，`externalChange` 以 `ExcalidrawScene.merge` 併進開啟中的場景、`flush` 立即存檔（避免外部寫入被舊場景覆蓋）
- [x] 型別化的 `Element` 包裝（底層仍是原始字典，未知欄位原樣保留）：共用欄位、各類型的欄位、`angle`、`groupIds`、`frameId`、`containerId`
- [x] 修改元素的共用路徑：遞增 `version`、重抽 `versionNonce`、更新 `updated`
- [x] fractional `index`：讀取排序、插入時產生、合併後排序；沒有 `index` 的舊檔案沿用陣列順序
- [x] 箭頭綁定：`startBinding` / `endBinding`（含 `fixedPoint`）與 `boundElements` 雙向維護；`rebindArrows(movedIDs:)` 重算端點
- [x] 文字：`containerId` 綁定、在容器內換行與置中的排版（CoreText，與渲染共用）
- [x] frame：`frameId` 子元素、移動 frame 帶動子元素
- [x] 圖片：插入時 ImageIO 縮到最長邊 2048px、JPEG、寫入 `files`；刪除元素時不刪 `files`（與 Excalidraw 相同）
- [x] 連結：`index()` 把 `link` 中的 `[[筆記]]` 收進 `links`；`renameLinks` 更新 `link` 與 `customData.easynotes.file`
- [x] 索引摘要改為「N 個元素」（筆畫與圖形合計）

驗收測試：

- [ ] 序列化：excalidraw.com 匯出的 fixture（含 6 種可建立的元素、diamond、line、elbow 箭頭、embeddable）讀入再寫出，元素與欄位不變；未知元素與欄位原樣保留
- [x] 修改一個元素只改變它的 `version` / `versionNonce` / `updated` 與被修改的欄位
- [x] fractional index：在兩元素之間插入 100 次，順序正確且 index 合法；兩邊各插入後合併，順序確定（兩台裝置結果相同）
- [x] 綁定：移動 / 縮放形狀後，綁定箭頭的端點落在形狀邊上（`gap` 正確）；刪除形狀後箭頭的 binding 清除；`boundElements` 與箭頭兩邊一致
- [x] 外部變動：開啟中的場景收到加了元素的 `externalChange` 後再存檔，該元素仍在
- [ ] 連結改名：白板中 `[[舊名]]` 的 `link` 跟著改名；反向連結出現白板

2026-10-02：4a 程式完成，`KindWhiteboard` 單元測試 39 個通過（`ModelSerializationTests`、`ModelEditingTests`、`BoardDocumentTests`；原有的 `InkRoundTripTests`、`InkMergeTests` 不變），macOS 與 iOS Simulator 建置成功。模型放在 `KindWhiteboard/Model/`（`Element`、`SceneEditor`、`Binding`、`TextLayout`、`FractionalIndex`、`Scene+Edit` / `+Image` / `+Links`）；開啟中的白板為 `BoardDocument`，由 `WhiteboardController`（`EditorController`）管理。

未勾的兩項：

- 序列化：fixture（`Tests/KindWhiteboardTests/Fixtures/excalidraw-export.excalidraw`）是依 Excalidraw 0.18 格式**手寫**的，涵蓋 6 種可建立的元素、diamond、line、elbow 箭頭、embeddable、未知類型與欄位、墓碑，來回測試通過。還要換成（或補上）excalidraw.com 實際匯出的檔案再驗一次才勾選。
- 連結改名：`renameLinks` 與 `index().links` 的單元測試通過；「反向連結出現白板」要在 App 內（VaultIndex 實際建立反向連結）驗證。

實作中的補充決定（見 Architecture「Whiteboard」）：

- `gap` = 端點到形狀輪廓的距離（射線與「輪廓向外擴 gap」的交點），不是沿射線往回退 gap。
- 沒有 `index` 的舊檔案不補 index（補了每個元素都要遞增 version）；新元素也不加 index，維持陣列順序。兩台裝置在同一處插入會得到相同 index，排序以 id 決定；之後再插入時跳過這串相同的 index。
- elbow 箭頭的端點不隨形狀重算（轉折路徑要重新走線，4c 以後再處理），綁定保留。
- 有透明度的圖片存 PNG，其他轉 JPEG（JPEG 沒有 alpha，透明處會變黑）。
- 箭頭單獨移動、但綁定的形狀沒一起移動 → 解除該端綁定（與 Excalidraw 相同）。

### 4b 渲染器、縮圖與嵌入

目標：白板在列表縮圖、md 嵌入與 Mac 上看起來正確；還不能編輯結構元素。

- [x] `SceneRenderer`（CoreGraphics，背景執行緒）：所有標準元素、`angle`、曲線與 elbow 箭頭與箭頭頭部、文字（系統字型）、圖片（依尺寸縮圖）、frame 裁切與標題；未知類型畫佔位框
- [ ] Core：`DocumentPreview.image: Data?`；`BoardPreview` 產生 PNG 縮圖、摘要
- [ ] EasyNotesUI：WebEditorHost 的 `embed://<路徑>?h=<hash>` scheme，回傳預覽快取中的 `image`
- [ ] Markdown：`![[x.excalidraw]]` 顯示為圖片 widget（游標所在行顯示原始語法），點擊開啟白板
- [ ] Mac 檢視改用 `SceneRenderer`（取代只顯示 `PKDrawing` 的畫面），可平移、縮放

驗收測試：

- [ ] 快照測試：fixture 渲染成 PNG 與基準圖比對（`EASYNOTES_SNAPSHOT_DIR`）
- [ ] 修改白板後，列表縮圖與 md 內的嵌入在數秒內更新；刪掉 `.easynotes/cache/preview/` 後重新產生，畫面相同
- [ ] 縮圖不在主執行緒產生；1,000 個元素的白板縮圖 < 200 ms（M 系列 Mac）
- [ ] 打字時不因嵌入圖片而經過 Bridge（`embed://` 由 WebView 自行載入）
- [ ] 手動：Mac 打開 excalidraw.com 畫的檔案，與網頁上的版面一致（除手繪風格與字型）

2026-10-02：`SceneRenderer` 完成（`KindWhiteboard/Render/`）。幾何（輪廓、Catmull-Rom 曲線、箭頭頭部、範圍）放在 `ElementGeometry`，4c 的 layer 樹共用同一份路徑；渲染器只負責上色、文字、圖片與 frame 裁切。快照測試（`RendererTests`）：基準圖在 `Tests/KindWhiteboardTests/Snapshots/`，`EASYNOTES_SNAPSHOT_RECORD=1` 重新錄製、`EASYNOTES_SNAPSHOT_DIR` 輸出這次的結果；容許 0.5% 像素差（字型抗鋸齒）。1,000 個元素的 PNG（1600px）在 M 系列 Mac 約 80 ms（Release）。快照驗收項目等 excalidraw.com 實際匯出的 fixture 補上再勾。

實作中的補充決定：

- 數值照 Excalidraw：圓角（`roundness.type` 3 固定 32、小形狀 25%；其他 25%）、箭頭頭部大小與角度、虛線 `[8, 8+w]`、點線 `[1.5, 6+w]`、首尾距離 ≤ 8 的 line 可填色。
- `fillStyle` 一律畫實心；frame 外框與標題用固定樣式（`#bbb` / `#999`），不看 `strokeColor`；`magicframe` 等未知類型畫佔位框。
- 手寫寬度：EasyNotes（PencilKit）筆畫用 `customData` 的點大小；excalidraw.com 的筆畫照 perfect-freehand（strokeWidth × 4.25、thinning 0.6）。半透明元素整個合成後才套用透明度。
- 文字直接用檔案中已換行的 `text`（Excalidraw 存檔時就換好行），不重新排版，避免字型寬度不同時跟網頁的換行不一樣。
- 圖片依顯示像素解碼（2 的冪次分級快取），支援 `crop`、`scale` 翻轉與圓角。

### 4c 編輯器

目標：可以日常使用的白板編輯。

- [ ] 依 S3 結論實作畫布：layer 結構層 + `PKCanvasView`、視窗裁切、點陣倍率跟著縮放（縮小時立即降低）
- [ ] LOD：縮放倍率低且畫面內 layer 超過門檻時改畫點陣快照，停止縮放後換回個別 layer
- [ ] 手勢：筆模式手指點一下選取、長按才拖曳；選取模式碰到就拖曳
- [ ] 工具列：筆 / 橡皮擦 / 套索（PencilKit）、選取、矩形、橢圓、箭頭、文字、圖片、frame
- [ ] 選取：點選、框選、Shift 多選；移動、控制點縮放；刪除；複製 / 貼上 / 再製
- [ ] 箭頭：拖到形狀上自動綁定；移動形狀時箭頭跟著走
- [ ] 文字：原生 `UITextView` / `NSTextView` 疊在元素上編輯，結束時寫回；雙擊形狀在其中加文字（`containerId`）
- [ ] 圖片：從照片、檔案、貼上插入
- [ ] Undo / Redo：結構操作註冊在 `PKCanvasView` 的 `undoManager`，與筆畫共用
- [ ] 存檔：停止操作 500 ms 後或離開時寫入；只遞增有變的元素
- [ ] macOS：同一個結構層加上滑鼠 / 觸控板互動（結構元素可編輯，手寫只能看）
- [ ] 鍵盤快捷鍵（Mac / iPad）：V 選取、R 矩形、O 橢圓、A 箭頭、T 文字、F frame、Delete、⌘D 再製

驗收測試：

- [ ] 手動：輸出檔在 excalidraw.com 開啟，箭頭仍綁在形狀上、文字在形狀內
- [ ] 移動形狀後綁定的箭頭跟著走（App 內與 excalidraw.com 都正確）
- [ ] 1,000 個元素的畫布縮放與平移仍流暢（iPad，同 S3 標準）
- [ ] 注音輸入：白板文字元素內組字正常
- [ ] Undo：交錯畫筆畫與移動形狀後連按 ⌘Z，依時間順序復原
- [ ] 多裝置：Mac 移動形狀、iPad 同時加筆畫 → 同步後兩邊都保留
- [ ] 開著白板時 Claude Code 加入一個 text 元素 → 數秒內出現在畫面，之後存檔不會消失
- [ ] 基準線符合非功能預算（記憶體：開著 1,000 個元素的白板）

### 4d 選做：筆記卡片

- [ ] 筆記卡片元素（rectangle + `link: [[筆記]]` + `customData.easynotes.file`，見 Architecture「筆記卡片放進白板」）
- [ ] 卡片內容向 Registry 要 `.md` 的預覽（不 import KindMarkdown）
- [ ] 點卡片在側邊面板開啟完整編輯器

驗收測試：

- [ ] 筆記改名後卡片仍指向它；在 excalidraw.com 顯示為帶連結的框

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

## Bug Repots

### Mobiles

- [x] 起始頁面是反向連結，應該要是筆記總覽 [R1]（2.5b：iPhone 改為底部分頁，啟動顯示所有文件）
- [x] 點擊檔案中的資料夾，會跳轉頁面：**選擇或建立一篇筆記** 所有筆記都存在 /var/mobile/... 應該要改成點擊後展開資料夾而非跳轉錯誤頁面 [R1]（2.5b：點資料夾改為推入資料夾頁，實機確認正常）
- [x] 當進入iOS > 複習 檢視所有卡牌，該頁面並沒有根據iOS手機螢幕（直立）進行排版優化（牌組列固定寬度的數字欄把內容撐出螢幕。compact 寬度改為：左右邊距 20、今日橫幅上下排且「開始複習」滿版、隱藏圖例、牌組列兩行〔名稱 + 選項 / 「● 數字 名稱」+ 複習〕，待實機確認）
- [x] 在 Mac 或 iOS 裝置的畫面頂端（狀態列或選單列附近）出現的小橘點，代表目前有 App 正在使用你的麥克風。 請確認是否有在Background執行或是存取麥克風等設備 → 不是麥克風：主畫面 App 名稱前的黃 / 橘點是 TestFlight 測試版的標記（App Store 版不會有）；麥克風指示燈在狀態列右上角。程式中沒有 AVAudio / AVCapture / Speech、沒有 `NSMicrophoneUsageDescription` 與 `UIBackgroundModes`，CM6 也不呼叫 `getUserMedia`

### Editor

- [x] Checklist 的 '[]' 勾選框太小，改成類似 Apple 備忘錄的圓形（自繪圓形 checkbox：1.2em、勾選填滿強調色、加大觸控熱區，待實機確認）

### Desktop

- [x] 點擊'未登入 不會同步'的按鈕要登入時，整個App會閃退，無法登入 -> 原因：TestFlight 安裝到 iPadOS
- [x] Collapse/Expand icon佔據很大比例，應該縮小移動至下方 -> 原因：TestFlight 安裝到 iPadOS
- [x] Sidebar Easynotes Icon 應該替換成App Icon 而不是'E'
- [x] App中顯示的檔案是默認的預設檔案 而不是 ~/Documents/Easynotes 內真實的檔案，點擊 '在「檔案」App中顯示 ' 也無法正常跳出Finder-> 原因：TestFlight 安裝到 iPadOS
- [x] 選擇Icon時，因為Light Theme的白色背景會看不到Icons（原因：文件頭的 SF Symbol 用 CSS mask 從 `symbol://` 載入，頁面是 `file://`，回應缺 CORS header 被 WebKit 丟掉，與主題無關；`SymbolSchemeHandler` 加上 `Access-Control-Allow-Origin` 後實機確認正常。選單也改用 text-primary 與格子邊框）

## 其餘功能清單

- [ ] Xmind - Mindmap
- [ ] Notion - Database 列表
- [ ] 需支援English (US) 可以在設定(cmd + ,)中設定，並使用English作為App預設語言
- [x] Upload Cover Image 支援Clipboard（封面選單新增「貼上剪貼簿的圖片」，⌘V；存成 PNG 後走一般附件路徑，待實機確認）

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
