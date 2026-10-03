# Roadmap 與 Todo

進度與驗收：每個 Phase 列出目標、工作項目與驗收測試，進度以勾選狀態為準；驗收測試全部通過才進入下一個 Phase。

**本文件只放**：目標、勾選清單、驗收測試、尚未驗證的事項、Bug 與風險。**不放**設計與決定的理由（寫在 [Architecture](./architecture/README.md) 與其下各功能檔）和版本變更（寫在 [Changelog](./Changelog.md)）。下表的「設計」欄是該 Phase 對應的 Architecture 檔案，整份讀即可。

## 狀態總覽

| Phase | 狀態 | 設計（`docs/architecture/`） |
| --- | --- | --- |
| 0 Spike + Prototype | 完成 | [README](./architecture/README.md)「技術選型決策」 |
| 1 本地筆記 MVP | 完成 | [markdown.md](./architecture/markdown.md) |
| 1.5 模組化重構 | 結構完成；`EditorState` LRU、Release 基準線延後 | [README](./architecture/README.md)「系統架構」、[core.md](./architecture/core.md)「擴充點」 |
| 2 同步 | 同步引擎與 App 串接完成；登入、衝突副本、整合與耗電驗收尚有未勾 | [core.md](./architecture/core.md)「同步設計」 |
| 2.5 UI 重構 | 完成；驗收測試尚有未勾 | [ui.md](./architecture/ui.md) |
| 3 Flashcards | 3a–3c 完成（實機驗證尚有未勾）；3d 未開始 | [flashcards.md](./architecture/flashcards.md) |
| 4 Whiteboard | S3、4a–4c 完成（手動驗證尚有未勾）；4d 選做 | [whiteboard.md](./architecture/whiteboard.md) |
| 5 PDF 手寫與標註 | S4、5a–5d 實作完成；手動驗證尚有未勾（匯入、伴隨檔流程、iPad 便利貼注音、同步合併、多裝置與大檔驗收） | [pdf.md](./architecture/pdf.md) |
| 6 Sheets | S5、6a–6d 實作完成（Swift 端未在 macOS / iOS 編譯與實機驗證）；驗收測試未勾 | [sheets.md](./architecture/sheets.md) |
| i18n 多語言（English (US)） | i0 基礎建設完成（在 `i18n-foundation` 分支，尚未合併；逐畫面比對尚未驗證）；i1 隨 Phase 5、6 進行；i2 英文翻譯在 Phase 6 之後 | [translation.md](./architecture/translation.md) |

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

延後項目：VaultWatcher 增量重掃已移到 Phase 2；`EditorState` LRU、Release 基準線與對應的驗收測試延後到 Phase 2 之後。

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

設計稿與 EasyNotes 模型的對應、字型（系統字型取代 Pen 的 Inter）、介面語言等決定見 [ui.md](./architecture/ui.md)。

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

### 2.5b 外殼與導覽

- [x] Desktop / iPad 側邊欄：Vault 標頭、搜尋（⌘K）、All Documents、Recents、Pinned、Spaces（可展開的檔案樹，檔案用類型圖示）、Tags、Recently Deleted、同步狀態、Settings
- [x] PluginRegistry 新增 `addPanel`，讓外掛加側邊欄項目，App 不寫死 Review
- [x] ⌘K 快速開啟：取代目前側邊欄的 `.searchable`，重用 FTS5 搜尋與 `HitRow`
- [x] 工具列：上一頁 / 下一頁、麵包屑（資料夾 / 檔名）、網格 / 列表、排序、在 Finder 中顯示、New Document 選單
- [x] New Document 選單與快捷鍵：新筆記 ⌘N、新白板 ⇧⌘N、匯入 PDF、匯入 CSV、新資料夾，項目來自 `addNewFile` / `addImport`
- [x] iPhone：底部分頁（Docs / Search / Spaces / Me），取代 `NavigationSplitView` 的摺疊行為
- [x] ~~反向連結：保留 inspector，套用新樣式~~ → 2026-10-02 決定移除反向連結 inspector（索引仍保留反向連結資料）

### 2.5c 文件列表

- [x] All Documents / 資料夾頁：標題 + 統計（文件數、資料夾數）、類型篩選、Pinned 區（Pin Card）、Recent 區（Desktop 網格、Mobile 列表）
- [x] 空狀態：空 Vault（`xGsaX`）、空資料夾（`m4Bb4`，顯示 Vault 內路徑，可拖入檔案）
- [x] 實作 `addPreview`（原生渲染，不開 WebView）：Markdown = 標題 + 前幾行；CSV / 白板 / PDF 先用 Thumb 元件的佔位樣式，各外掛完成後再換成真實縮圖
- [x] 卡片副標：外掛提供一行摘要（字數、列數、頁數）＋相對時間
- [x] 預覽快取：依 hash 存在 `.easynotes/cache/preview/`，檔案未變就不重算
- [x] 索引補欄位：frontmatter 的 `icon`、`pinned`、字數（`IndexEntry` 新增欄位，Core 只存不解讀）

### 2.5d 編輯器

- [x] Markdown 文件頭：frontmatter 在 CM6 以 block widget 顯示為封面、icon、標題、meta（標籤、最後編輯時間），游標進入時才顯示原始 YAML
- [x] 更換封面 / icon：寫回 frontmatter（經 Vault，走一般的寫檔與同步路徑）
- [x] 封面圖片由 `WKURLSchemeHandler` 從 Vault 讀取
- [x] Live Preview 樣式對齊設計稿：callout（`> [!tip]`）、核取清單、引言、`[[連結]]` 獨占一行時顯示為連結卡片（含目標檔案的類型圖示）
- [x] 浮動格式工具列（Desktop 右下）與 iOS 鍵盤工具列（`Format Bar`）：原生 SwiftUI，按下時送 `exec`，不在打字路徑上
- [x] 工具列：麵包屑、同步狀態、釘選、更多選單（在 Finder 中顯示、複製路徑、用其他 App 開啟）
- [x] Mobile 編輯器：返回所在資料夾、同步狀態、釘選、分享（系統 Share Sheet 分享檔案）、更多

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

設計見 [flashcards.md](./architecture/flashcards.md)。

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

尚未在實機驗證：語法標示的外觀、注音組字、FSEvents 觸發後數秒內補上 id。

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

尚未驗證：復原的卡片狀態回復只測了紀錄檔層（`ReviewStore` 沒有單元測試）、多裝置同步、實機畫面與設計稿比對（含淺色、iPhone 版面）、「編輯筆記」捲到該行。

設計稿節點（深色）：牌組列表 `rHTaT`、複習 `b2AjRQ`、牌組選項 `AYlad`。範圍與取捨見 [flashcards.md](./architecture/flashcards.md)。

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

分 Spike 與四個子階段，依序進行：S3 先驗證最有風險的畫布架構；4a 不需要介面，全部可用單元測試驗證；4b 完成後白板可在縮圖、嵌入與 Mac 檢視；4c 完成後可日常使用；4d 選做。

### S3 Spike：畫布架構（iPad 實機）

目標：在寫正式程式前，確認「layer 結構層 + `PKCanvasView` 手寫層」的組合可行。不通過就先改 [whiteboard.md](./architecture/whiteboard.md) 的設計再進 4c。

- [x] 原型（外掛內的 `Spike/CanvasSpike.swift`，側邊欄「畫布 Spike」面板）：`PKCanvasView` 底下一個 layer 結構層，畫 1,000 個隨機矩形 / 橢圓 / 箭頭 / 文字
- [x] 結構層跟著 `PKCanvasView` 的 `contentOffset` / `zoomScale` 移動；縮放結束時重設 `contentsScale`
- [x] 手勢分工：Pencil 畫圖、手指捲動縮放、手指點選圖形（hit test）並拖曳
- [x] 選取工具時 Pencil 也能選取與拖曳（切換 `drawingPolicy` 或停用 `drawingGestureRecognizer`）→ 併入 4c：非手寫模式停用 `drawingGestureRecognizer`，2026-10-02 實機確認
- [x] 視窗裁切：只為畫面內（加一圈緩衝）的元素建立 layer

驗收測試（iPad 實機，Release build）：

- [x] 1,000 個元素時平移、縮放維持 ProMotion 下 ≥ 60 fps（Instruments Animation Hitches 無明顯卡頓）
- [x] 縮放到 4× 後線條與文字清晰（不是點陣放大）
- [x] 手寫筆畫與結構層在平移、縮放中始終對齊（無位移、無延遲一幀）
- [x] 手指捲動時不會畫出筆畫；Pencil 書寫延遲與現有手寫畫面相同
- [x] 記錄結論與數據到本節，必要時修改 [whiteboard.md](./architecture/whiteboard.md)

結論（iPad Air M1、60Hz，五輪實機）：驗收全部通過。1,000 個元素維持 60 FPS（該機型上限），10,000 個元素約 30 FPS（由 4c 的 LOD 處理）。實作規則（transform 同步、關閉縮放回彈、點陣倍率、文字 layer 關閉 `contents` 動作）已寫入 [whiteboard.md](./architecture/whiteboard.md)。原型用法：側邊欄「畫布 Spike」面板只在 DEBUG 或啟動參數 `-WhiteboardSpike YES` 時出現（Release build 量測幀率），不讀寫 Vault。

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

未勾的兩項：

- 序列化：fixture（`Tests/KindWhiteboardTests/Fixtures/excalidraw-export.excalidraw`）是依 Excalidraw 0.18 格式**手寫**的，涵蓋 6 種可建立的元素、diamond、line、elbow 箭頭、embeddable、未知類型與欄位、墓碑，來回測試通過。還要換成（或補上）excalidraw.com 實際匯出的檔案再驗一次才勾選。
- 連結改名：`renameLinks` 與 `index().links` 的單元測試通過；「反向連結出現白板」要在 App 內（VaultIndex 實際建立反向連結）驗證。

### 4b 渲染器、縮圖與嵌入

目標：白板在列表縮圖、md 嵌入與 Mac 上看起來正確；還不能編輯結構元素。

- [x] `SceneRenderer`（CoreGraphics，背景執行緒）：所有標準元素、`angle`、曲線與 elbow 箭頭與箭頭頭部、文字（系統字型）、圖片（依尺寸縮圖）、frame 裁切與標題；未知類型畫佔位框
- [x] EasyNotesUI：`DocumentPreview.image: Data?`（快取另存 `<hash>.png`）；`BoardPreview` 產生 PNG 縮圖、摘要
- [x] EasyNotesUI：WebEditorHost 的 `embed://<路徑>?h=<hash>` scheme，回傳預覽快取中的 `image`
- [ ] Markdown：`![[x.excalidraw]]` 顯示為圖片 widget（游標所在行顯示原始語法），點擊開啟白板
- [ ] Mac 檢視改用 `SceneRenderer`（取代只顯示 `PKDrawing` 的畫面），可平移、縮放

驗收測試：

- [ ] 快照測試：fixture 渲染成 PNG 與基準圖比對（`EASYNOTES_SNAPSHOT_DIR`）
- [ ] 修改白板後，列表縮圖與 md 內的嵌入在數秒內更新；刪掉 `.easynotes/cache/preview/` 後重新產生，畫面相同
- [ ] 縮圖不在主執行緒產生；1,000 個元素的白板縮圖 < 200 ms（M 系列 Mac）
- [ ] 打字時不因嵌入圖片而經過 Bridge（`embed://` 由 WebView 自行載入）
- [ ] 手動：Mac 打開 excalidraw.com 畫的檔案，與網頁上的版面一致（除手繪風格與字型）

待驗證：快照驗收項目等 excalidraw.com 實際匯出的 fixture 補上再勾（基準圖在 `Tests/KindWhiteboardTests/Snapshots/`，`EASYNOTES_SNAPSHOT_RECORD=1` 重新錄製、`EASYNOTES_SNAPSHOT_DIR` 輸出這次結果）；`![[x.excalidraw]]` 嵌入程式已完成，待 App 內手動驗證後勾選。

### 4c 編輯器

目標：可以日常使用的白板編輯。

- [x] 依 S3 結論實作畫布：layer 結構層 + `PKCanvasView`、視窗裁切、點陣倍率跟著縮放（縮小時立即降低）
- [x] LOD：縮放倍率低且畫面內 layer 超過門檻時改畫點陣快照，停止縮放後換回個別 layer
- [x] 手勢：手寫模式手指點一下選取、長按才拖曳；非手寫模式 Pencil 與手指碰到元素就拖曳
- [x] 工具列（Freeform 式，見 [whiteboard.md](./architecture/whiteboard.md)「工具列改版」）：畫筆（手寫模式，顯示 `PKToolPicker`）、便條紙、形狀（矩形、圓角矩形、橢圓、菱形、箭頭、frame）、文字框、圖片；插在畫面中央
- [x] 畫布背景：無 / 網格 / 點狀（App 偏好設定，不寫進檔案）
- [x] 選取方式：矩形 / 套索，工具列按鈕切換（只選結構元素；筆畫用 PencilKit 套索）
- [x] 選取：點選、框選、Shift 多選；移動、控制點縮放；刪除；複製 / 貼上 / 再製
- [x] 箭頭：拖到形狀上自動綁定；移動形狀時箭頭跟著走
- [x] 箭頭連接點：形狀上下左右 4 個連接點，拖曳端點靠近時吸附並寫入 `fixedPoint`（見 [whiteboard.md](./architecture/whiteboard.md)「4c：箭頭連接點吸附」；不做轉折線與曲線）
- [x] 文字：原生 `UITextView` / `NSTextView` 疊在元素上編輯，結束時寫回；雙擊形狀在其中加文字（`containerId`）
- [x] 圖片：從照片、檔案、貼上插入
- [x] Undo / Redo：結構操作註冊在 `PKCanvasView` 的 `undoManager`，與筆畫共用
- [x] 存檔：停止操作 500 ms 後或離開時寫入；只遞增有變的元素
- [x] macOS：同一個結構層加上滑鼠 / 觸控板互動（結構元素可編輯，手寫只能看）
- [x] 鍵盤快捷鍵（Mac / iPad）：V 選取、R 矩形、O 橢圓、A 箭頭、T 文字、F frame、Delete、⌘D 再製
- [x] 樣式面板（見 [whiteboard.md](./architecture/whiteboard.md)「4c：樣式面板」）：填色、外框顏色 / 粗細 / 線型、圓角、箭頭端點、文字顏色 / 大小 / 對齊、透明度；只用預設色盤；新元素沿用上次的樣式

驗收測試：

- [x] 手動：輸出檔在 excalidraw.com 開啟，箭頭仍綁在形狀上、文字在形狀內
- [x] 移動形狀後綁定的箭頭跟著走（App 內與 excalidraw.com 都正確）
- [x] 1,000 個元素的畫布縮放與平移仍流暢（iPad，同 S3 標準）
- [x] 注音輸入：白板文字元素內組字正常
- [x] Undo：交錯畫筆畫與移動形狀後連按 ⌘Z，依時間順序復原
- [x] 多裝置：Mac 移動形狀、iPad 同時加筆畫 → 同步後兩邊都保留
- [ ] 開著白板時 Claude Code 加入一個 text 元素 → 數秒內出現在畫面，之後存檔不會消失
- [ ] 基準線符合非功能預算（記憶體：開著 1,000 個元素的白板）

### 4d 選做：筆記卡片

- [ ] 筆記卡片元素（rectangle + `link: [[筆記]]` + `customData.easynotes.file`，見 [whiteboard.md](./architecture/whiteboard.md)「筆記卡片放進白板」）
- [ ] 卡片內容向 Registry 要 `.md` 的預覽（不 import KindMarkdown）
- [ ] 點卡片在側邊面板開啟完整編輯器

驗收測試：

- [ ] 筆記改名後卡片仍指向它；在 excalidraw.com 顯示為帶連結的框

## Phase 5 — PDF 手寫與標註

目標：在上課 PDF 上用基本工具手寫，原始 PDF 不被修改。

分 Spike 與四個子階段，依序進行：S4 先驗證疊層架構；5a 不需要介面，全部可用單元測試驗證；5b 完成後 PDF 可在列表與兩個平台檢視；5c 完成後 iPad 可日常標註；5d 匯出。

### S4 Spike：PDF 疊層（iPad 實機）

目標：確認「`PDFView` + 每頁 overlay `PKCanvasView`」可行，不通過就先改 [pdf.md](./architecture/pdf.md) 再進 5c。

- [x] `PDFView` + `PDFPageOverlayViewProvider` + `PKCanvasView`（`isInMarkupMode`）
- [x] 縮放後筆畫清晰、與頁面對齊；Pencil 書寫、手指捲動縮放
- [x] 所有頁面共用一個 `PKToolPicker`
- [x] 私有 `undoManager` 吞掉 PencilKit 的 undo，改在模型註冊，overlay 回收後仍可跨頁復原
- [x] 200 頁快速捲動，記憶體穩定

### 5a 模型與格式（無 UI，單元測試）

- [x] 抽出 `ExcalidrawKit`（元素模型、merge、`InkStroke`、`ElementGeometry`、`TextLayout`、`ElementPainter`、`SceneRenderer`），KindWhiteboard 測試全部通過
- [x] `.pdf.ink` 讀寫、頁面座標換算（含 `rotation`、cropBox）
- [x] `PDFKind`（不透明）+ `PDFInkKind`（依頁 + 元素合併）
- [x] Core 伴隨檔案：檔案樹 / 列表 / 搜尋隱藏；App 內改名、搬移、刪除、還原一起處理；孤兒旁檔以 `pdfHash` 認領
  - 單元測試涵蓋 VaultFS、VaultIndex、SyncEngine 與 `PDFInk.claimOrphan`；`VaultStore` 的串接（改名 / 刪除通知同步與編輯器、伴隨檔的 `externalChange`）只確認建置成功，尚未驗證。Kind 在 5b 才註冊，App 內目前看不到 PDF。

### 5b 檢視、縮圖與 Mac

- [ ] 唯讀 PDF + 標註（兩個平台）、列表縮圖（第 1 頁）、「匯入 PDF…」
  - iPad Simulator 已驗證：標註與頁面對齊（直式、橫式、`rotation` 90）、螢光筆透明度、便利貼文字；列表縮圖、頁數、PDF 篩選 chip、`.pdf.ink` 不出現在列表。
  - Mac App 已驗證：列表縮圖正常、關閉重開後標註仍保存、放大後便利貼與筆畫清晰。
  - 尚未驗證：iPad 實機放大後的清晰度（Simulator 無法縮放）、「匯入 PDF…」實際匯入、孤兒旁檔認領後的同步通知（`fileMoved`）。
- [x] `pdfHash` 不符時提示「PDF 已變更，標註可能錯位」
  - iPad Simulator 顯示提示列；「保留標註」只由單元測試驗證（`PDFInkDocumentTests`），尚未在 App 內按過。
- [x] Mac：便利貼新增、移動、縮放、編輯（`NSTextView`）
  - Mac App 已驗證：新增並以注音輸入（組字中 Esc 只取消選字）、拖曳（預覽完整、放開不閃回原位）、滑過顯示外框與縮放點、縮放（文字重新換行、最小 40 pt）、右鍵編輯與刪除。

### 5c iPad 編輯器

- [x] 可見頁面才建立 `PKCanvasView`，回收時筆畫換回 elements
  - iPad 實機已驗證：書寫、縮放流暢且筆畫清晰、Undo / Redo、關閉重開後筆畫保存。
- [x] 工具列：畫筆開關（`PKToolPicker`：鋼筆、螢光筆、橡皮擦、套索）、便利貼、匯出、Undo / Redo
  - 畫筆開關與 Undo / Redo iPad 實機已驗證；便利貼按鈕隨 5c 便利貼一起加；匯出按鈕（5d）實測可用。
- [ ] 便利貼：插入、移動、縮放、`UITextView` 編輯
  - 實作完成（含工具列的「便利貼」按鈕、選取選單的編輯 / 刪除、模型 Undo）。
  - iPad 第一輪回報：手指與 Pencil 無法移動、縮放；書寫或打字時看到便利貼底下的文字；書寫時明顯延遲、掉幀。已修正（手勢改裝在 PDFView 外層、筆畫改變不再重畫標註層、文字框不透明且延後移除），iPad 實機已驗證：移動、縮放、不再露出底下文字、延遲明顯改善。
  - iPad 實機已驗證：手寫模式中 Pencil 可以寫在便利貼上；筆畫不會跟著便利貼移動（見「待決事項」）。iPad 便利貼內注音輸入尚未驗證。已知：鍵盤可能蓋住頁面下方的便利貼（PDFView 不會自動捲動）；旋轉頁上的編輯框不跟著旋轉。
- [ ] 停止操作 500 ms 後存檔；`EditorController` 的 `externalChange` 合併、`flush`
  - 實作完成：500 ms 存檔、`externalChange` 合併與 `flush` 由單元測試驗證（`PDFInkDocumentTests`）；iPad 實機已驗證關閉重開後筆畫保存；合併後可見頁的畫布重新載入筆畫尚未在 App 內驗證。
- [ ] 選做：畫完一筆後停住（長按）變成直線（GoodNotes 式）

### 5d 匯出

- [x] `CGPDFContext` 逐頁畫原頁面 + 向量標註，分享或存成 `<檔名>（標註）.pdf`
  - `PDFExporter` 由單元測試驗證（`PDFExporterTests`：旋轉頁的輸出尺寸與筆畫位置、便利貼是可搜尋的向量文字、原始 PDF 不變、取消不留檔、檔名自動編號）；App 內實測匯出成功。
  - 尚未逐項驗證：匯出中取消、200 頁以上大檔的速度與記憶體。
- [x] 移除 S4 Spike 面板（`PDFOverlaySpike`），結論已寫入 [pdf.md](./architecture/pdf.md)

驗收測試：

- [x] 縮放、捲動後筆畫位置正確；關閉重開後完整還原
- [ ] 旋轉頁面上的筆畫位置正確（App 內與匯出）
- [ ] 200 頁 PDF 快速捲動，記憶體穩定（Instruments 觀察）
- [ ] 跨頁交錯書寫後連按 ⌘Z，依時間順序復原（含已捲出畫面的頁）
- [ ] 標註前後原始 PDF 的 hash 不變
- [ ] App 內改名、搬移、刪除再還原 PDF，旁檔跟著走
- [ ] 多裝置：兩台在不同頁同時標註 → 同步後兩邊都保留
- [ ] 便利貼內注音輸入正常（iPad、Mac）
  - Mac 已驗證（5b）；iPad 待 5c。
- [ ] 手動：匯出的 PDF 在「預覽程式」中正確顯示筆畫、螢光筆與便利貼

## Phase 6 — Sheets

目標：用 RevoGrid 編輯 CSV / TSV，不影響其他工具讀取。

分 Spike 與四個子階段，依序進行：S5 先驗證注音與效能；6a 不需要介面，全部可用單元測試驗證；6b 完成後可日常編輯；6c 顯示設定；6d 預覽、嵌入與新增匯入。

### S5 Spike：RevoGrid 注音與效能（iPad 實機 + Mac）

目標：確認 RevoGrid 在 WKWebView 中可用，不通過就先改 [sheets.md](./architecture/sheets.md)（自寫 TS 虛擬表格或原生表格）再進 6b。

- [x] 選取儲存格後直接以注音打字：第一個字不吃字、不重複（隱藏 `textarea` 常駐焦點）
- [x] 組字中按 Enter 不結束編輯（`isComposing`）
- [x] 1 萬列捲動流暢（iPad、Mac）
- [x] bundle 大小在預算內（約 0.5–1 MB）
- [x] 關閉表格後 WebContent process 釋放

### 6a 模型與格式（無 UI，單元測試）

- [x] 新增 `Packages/KindSheet`（只依賴 EasyNotesCore / EasyNotesUI；App 的 `project.yml` 在 6b 註冊外掛時再加）
- [x] RFC 4180 解析與序列化，`.csv` / `.tsv` 共用；記錄保留原始位元組
- [x] 風格偵測：換行符、引號風格、BOM、檔尾換行；欄數不一的列原樣保留
- [x] 編碼：UTF-8 可編輯；Big5 唯讀 + 「轉成 UTF-8」
- [x] `index()`：儲存格文字（設上限）、摘要「N 列 · M 欄」、`[[連結]]` 與 `renameLinks`
- [x] 以記錄為單位的 diff3 + 同一記錄的儲存格三方合併（Core 的 `Diff3.merge` 加上 `resolve`）
- [ ] 驗證：macOS 上 `(cd Packages/KindSheet && swift test)` 與 Core 的 `swift test` 全過（含 Big5 測試，CP950 只在 Apple 平台可用）
  - 目前在 Linux（Swift 6.2）以 Core 的 `Diff3` / `DocumentKind` 加 KindSheet 原始碼組成的測試環境驗證：60 個測試通過，Big5 測試略過。

### 6b 編輯器（WebView）

- [x] `web/src/sheet` entry，打包進 KindSheet 的 Resources（`sheet.js` 約 336 KB）
- [x] 每次開檔建立自己的 `WebEditorHost`、關閉後釋放
- [x] Bridge：`load({rows, meta})`（穩定 row id）、`edit({ops})` 只在儲存格編輯結束時送、延遲 300 ms 寫檔
- [x] `EditorController`：`externalChange` → `applyRemote`（保留選取）、`flush`
- [x] 增刪列欄、JS 端 Undo、TSV 剪貼簿、`addMenu("表格")`
- [x] 排序與篩選只影響畫面；「依此欄排序並寫入」
- [x] `addKind`（CSV、TSV）先在 6b 註冊，否則無法開檔；App 的 `project.yml`、`EasyNotes.xcodeproj` 與外掛清單加入 KindSheet
- [ ] 驗證：macOS 與 iOS 建置、實機開啟與編輯 CSV（含注音、TSV 剪貼簿、⌘Z、外部修改即時更新、關閉後 WebContent process 結束）
  - 目前只在 Linux 的 Chromium（Playwright）驗證 JS 端：打字、插入 / 刪除列欄、復原 / 重做、數值排序並寫入、Delete 清除、外部變動保留選取與編輯中延後套用、1 萬列載入約 0.1 秒。Swift 端（`SheetSession`、`SheetEditorView`、`SheetPlugin`）未編譯過。
  - `EasyNotes.xcodeproj` 是手動加入 KindSheet 的（沒有跑 `xcodegen generate`），下次 `xcodegen generate` 會重新產生。
  - 已知限制：標題列（固定在上方的第一列）要按 Enter 或雙擊才能編輯，不能選取後直接打字。

### 6c 顯示設定

- [x] `.csv.meta.json` / `.tsv.meta.json`（欄寬、凍結欄、標題列）；只在改了顯示設定時建立
- [x] 以 `companionOf` 註冊為伴隨檔；增刪欄時一起調整；以欄位三方合併（兩邊都改時本地優先）
- [ ] 驗證：macOS 與 iOS 建置、`swift test`（`SheetMetaTests`）、實機調整欄寬 / 凍結首欄 / 第一列是標題後重開仍保留、改名搬移刪除時旁檔跟著走、兩台各改不同設定同步後合併
  - 目前只在 Linux 的 Chromium（Playwright）驗證 JS 端：載入時套用欄寬與凍結欄、切換凍結 / 標題列送出 `meta`、關掉標題列後排序並寫入包含第一列、插入 / 刪除欄（含復原）移動欄寬與凍結欄數、拖曳欄寬送出寬度、`applyMeta` 重畫。這個環境沒有 Swift 工具鏈（`download.swift.org` 被網路政策擋住），`SheetMeta` 與 `SheetSession` 的修改未編譯過，`SheetMetaTests` 未執行。

### 6d 預覽、嵌入、新增與匯入

- [x] 列表縮圖（CoreGraphics PNG，Thumb CSV `otUrV`）
- [x] md 內 `![[x.csv]]` 嵌入預覽（`embed://`，深色模式反相）
- [x] `addNewFile("新表格")`、`addImport("匯入 CSV…")`（`addKind` 已在 6b 完成）
- [x] `addVaultGuide`：CSV 慣例
- [ ] 驗證：macOS 與 iOS 建置、`swift test`（`SheetPreviewTests`）、列表縮圖與 `![[x.csv]]` 嵌入在淺色 / 深色模式的樣子、「新表格」與「匯入 CSV…」、新 Vault 的 `CLAUDE.md` 含表格一節
  - 這個環境沒有 Swift 工具鏈也沒有 CoreGraphics，`SheetPreview` 未編譯、PNG 未實際畫過；`embed://` 與 Markdown 的嵌入沿用白板的機制，沒有改動。

驗收測試：

- [ ] 未修改的 CSV / TSV 寫回後逐位元組相同（含 CRLF、BOM、全部加引號的檔案）
- [ ] 含引號、逗號、換行、中文、emoji 的欄位來回不變
- [ ] 儲存格內注音輸入正常（iPad、Mac），含選取後直接打字
- [ ] 1 萬列捲動流暢
- [ ] 開著表格時 Claude Code 修改檔案，畫面即時更新且不被舊內容覆蓋
- [ ] 多裝置：兩台離線修改不同列 → 同步後自動合併；同一列不同儲存格 → 也自動合併
- [ ] Big5 檔案開啟不損壞
- [ ] 關閉表格後 WebContent process 結束（記憶體預算）

## i18n — 多語言（English (US)）

目標：介面支援 zh-Hant 與 English (US)；預設跟隨系統，系統語言不在清單時用 English；Mac 可在設定（⌘,）選語言。

分三段：i0 基礎建設先做，做完後新程式碼不再增加寫死的中文；i1 是 Phase 5、6 開發期間要遵守的規則；i2 等功能穩定（Phase 6 完成）後一次補英文，只翻一次。i0 在獨立分支進行，不影響 Phase 5 的分支；合併前先確認 `swift test` 與兩個平台建置通過。

### i0 基礎建設（不改變任何畫面：zh-Hant 輸出與遷移前逐字相同）

- [x] 設計：[translation.md](./architecture/translation.md)、README 的導覽列、CLAUDE.md 的規則
- [x] 每個有中文的模組加 `Localizable.xcstrings`、`Package.swift` 的 `defaultLocalization` 與 `resources`、`Localization.swift`（`L(_:)`）：App、EasyNotesCore、EasyNotesUI、ExcalidrawKit、KindMarkdown、KindWhiteboard、KindPDF、Flashcards（catalog 目前是空的：key 就是中文原文，查不到回傳 key；補 `en` 在 i2。每個模組有 `LocalizationTests` 確認 `#bundle` 可用）
- [x] 既有 Swift 中文字面值（415 個）改走 `L(…)`；Spike 面板不翻
- [x] 固定字串標 `// l10n:fixed`：`Attachments` 與舊版 `附件`、衝突副本命名（`SyncEngine.conflictMarker` / `isConflictCopy`，`DocumentToolbar` 改用它辨識）、Vault 的 `CLAUDE.md` 與各外掛 `guide`、預設 preset 名稱「預設」、Seed 範例內容（整檔標 `l10n:fixed-file`，依語言產生留到 i2）
- [x] 沒有手拼的中文：「N 字」用目前語言的數字格式（原本固定 `zh-Hant`）
- [x] Web：中文收進 `web/src/shared/i18n.ts`（`t()`、`Intl`）；Swift 建立 WebView 時注入 `window.__locale`；「N 分鐘前編輯」改成整句 key；`tsc` 與 `npm run build` 通過。WebView 內的實際畫面尚未驗證
- [x] `scripts/check-l10n.py`：Swift 與 Web 沒有違規
- [x] 驗證：各 package `swift test` 全過；macOS 與 iOS Simulator 以 `xcodebuild` 建置成功；iOS Simulator（iPhone 17）啟動、文件列表顯示正常的繁體中文
- [ ] 驗證：逐畫面與遷移前比對 zh-Hant（Mac、iPad、編輯器 WebView、白板、複習）；Mac 版尚未啟動過（尚未驗證）

### i1 開發期規則（Phase 5、6 期間）

- [ ] 新功能的文字一律走 `L(…)` / `t(…)`，`check-l10n.py` 沒有新增違規

### i2 英文翻譯（Phase 6 完成後）

- [ ] 各模組 catalog 補 `en`（含複數 variations）；`CFBundleDevelopmentRegion` 改 `en`、`CFBundleLocalizations` 加 `en`；系統選單跟著變英文
- [ ] 索引記錄產生時的語言，語言改變時整份重建（`summary` 是顯示文字）
- [ ] Mac 設定（⌘,）的語言選項（寫入 `AppleLanguages`，提示重新啟動）；iOS 以系統設定切換
- [ ] Web 端 `en` 字典
- [ ] 首次啟動的範例內容（`Seed`）依介面語言產生

驗收測試：

- [ ] zh-Hant 系統：畫面與 i0 之前逐字相同
- [ ] English 系統：所有畫面沒有殘留中文（含 WebView、系統選單、錯誤訊息、空狀態）
- [ ] 系統語言為 fr 等不支援的語言：顯示 English
- [ ] Double-Length Pseudolanguage：iPhone、iPad、Mac 沒有截斷或破版
- [ ] 複數：1 與多個（卡片數、文件數、頁數）
- [ ] 切換語言後索引重建，列表摘要的語言正確
- [ ] 兩台不同語言的裝置同步同一個 Vault：不會因語言產生衝突副本
- [ ] English 介面下注音輸入正常（iPad、Mac）

## Bug Reports

### Mobiles

- [x] 起始頁面是反向連結，應該要是筆記總覽 [R1]（2.5b：iPhone 改為底部分頁，啟動顯示所有文件）
- [x] 點擊檔案中的資料夾，會跳轉頁面：**選擇或建立一篇筆記** 所有筆記都存在 /var/mobile/... 應該要改成點擊後展開資料夾而非跳轉錯誤頁面 [R1]（2.5b：點資料夾改為推入資料夾頁，實機確認正常）
- [x] 當進入iOS > 複習 檢視所有卡牌，該頁面並沒有根據iOS手機螢幕（直立）進行排版優化（牌組列固定寬度的數字欄把內容撐出螢幕。compact 寬度改為：左右邊距 20、今日橫幅上下排且「開始複習」滿版、隱藏圖例、牌組列兩行〔名稱 + 選項 / 「● 數字 名稱」+ 複習〕，待實機確認）
- [x] 在 Mac 或 iOS 裝置的畫面頂端（狀態列或選單列附近）出現的小橘點，代表目前有 App 正在使用你的麥克風。 請確認是否有在Background執行或是存取麥克風等設備 → 不是麥克風：主畫面 App 名稱前的黃 / 橘點是 TestFlight 測試版的標記（App Store 版不會有）；麥克風指示燈在狀態列右上角。程式中沒有 AVAudio / AVCapture / Speech、沒有 `NSMicrophoneUsageDescription` 與 `UIBackgroundModes`，CM6 也不呼叫 `getUserMedia`

### Review

- [ ] 當卡片都複習完時，"開始複習" 按鈕應該會變灰色不可點擊
- [ ] 自定義複習 (Custom Study)

### Editor

- [x] Checklist 的 '[]' 勾選框太小，改成類似 Apple 備忘錄的圓形（自繪圓形 checkbox：1.2em、勾選填滿強調色、加大觸控熱區，待實機確認）

### Desktop

- [x] 點擊'未登入 不會同步'的按鈕要登入時，整個App會閃退，無法登入 -> 原因：TestFlight 安裝到 iPadOS
- [x] Collapse/Expand icon佔據很大比例，應該縮小移動至下方 -> 原因：TestFlight 安裝到 iPadOS
- [x] Sidebar Easynotes Icon 應該替換成App Icon 而不是'E'
- [x] App中顯示的檔案是默認的預設檔案 而不是 ~/Documents/Easynotes 內真實的檔案，點擊 '在「檔案」App中顯示 ' 也無法正常跳出Finder-> 原因：TestFlight 安裝到 iPadOS
- [x] 選擇Icon時，因為Light Theme的白色背景會看不到Icons（原因：文件頭的 SF Symbol 用 CSS mask 從 `symbol://` 載入，頁面是 `file://`，回應缺 CORS header 被 WebKit 丟掉，與主題無關；`SymbolSchemeHandler` 加上 `Access-Control-Allow-Origin` 後實機確認正常。選單也改用 text-primary 與格子邊框）
- [ ] 左側的Sidebar, 雙點擊檔案或資料夾要可以重新命名，資料夾與檔案可以點擊拖拽到其他位置

## 其餘功能清單

- [ ] Xmind - Mindmap
- [ ] Notion - Database 列表
- [ ] 需支援English (US) 可以在設定(cmd + ,)中設定，並使用English作為App預設語言（見上方「i18n」）
- [ ] Settings > 支援Light/Dark Theme
- [x] Upload Cover Image 支援Clipboard（封面選單新增「貼上剪貼簿的圖片」，⌘V；存成 PNG 後走一般附件路徑，待實機確認）

## 風險與待決事項

| 風險 | 影響 | 緩解 |
| --- | --- | --- |
| 同步資料遺失 | 信任崩潰 | 內容定址 Storage 只增不覆寫、伺服器端版本檢查、diff3 合併、衝突副本、軟刪除 |
| 外部工具改名被視為刪除 + 新增 | 失去歷史與合併基準 | 以 hash 推斷改名；最差情況只失去歷史，不遺失內容 |
| 外掛介面設計過早 | 後續外掛被錯誤的抽象綁住 | Markdown 先走外掛介面；擴充點等第二個外掛需要時才抽出 |
| WebView 記憶體 | iPhone 後台被殺 | 單一共用 WebView，多分頁共用一個 process pool |
| PDF 大檔記憶體 | 閃退 | 只為可見頁面建立 `PKCanvasView`，離開畫面就回收 |
| RevoGrid 在 WKWebView 的注音輸入 | 表格無法輸入中文 | S5 Spike 最先驗證；不通過改用自寫 TS 虛擬表格或原生表格 |
| `PKCanvasView` 只支援 iOS | macOS 無法手寫 | 接受：macOS 只顯示手寫，結構元素仍可編輯 |
| swift-fsrs 版本落後 | 排程與 Anki 不一致 | 以 fsrs-rs 參考向量做回歸測試；必要時改用 fsrs-rs 的 UniFFI 綁定做排程 |
| 套件授權 | 個人使用影響很小 | 仍優先選 MIT / BSD：RevoGrid（MIT）、fsrs-rs（BSD-3） |

待決事項：

- [x] macOS 上 vault 要放使用者可見的資料夾（可用 Finder / 其他編輯器開），還是 App 沙盒內？
- [x] Sheets 是否需要公式？→ 不需要。CSV 只存資料，需要公式時用外部 App 開啟。
- [x] 是否需要 Android / Web 版？→ 不需要。個人使用，只支援 Apple 平台。
- [ ] Sheets 的排序與篩選狀態要不要記住？（建議：只存在這台裝置，不同步；Phase 6 開工時決定）
- [x] 附件資料夾名稱 → `Attachments/`（固定英文，不隨介面語言）。舊版的 `附件/` 不搬動、不改寫連結，`vault://` 在 `Attachments/` 找不到時改找 `附件/`（單元測試涵蓋路徑對應；實機開啟舊筆記的圖片與封面尚未驗證）
- [x] Vault 的 `CLAUDE.md` 要固定哪一種語言？→ 英文。只在檔案不存在時建立，所以既有 Vault 裡的中文版不會被改寫，要換自己刪掉重建（尚未驗證）
- [ ] PDF 便利貼上的手寫要不要跟著便利貼移動？目前筆畫與便利貼是各自獨立的元素，移動便利貼時筆畫留在原處（GoodNotes 的做法是跟著走，需要記錄筆畫屬於哪張便利貼）
- [ ] `DocumentKind.index()` 的 `summary` 長期是否改成不含語言的結構化資料，取代 i2 的「語言改變就重建索引」

Vault 位置已決定：macOS 用可見資料夾 `~/Documents/EasyNotes`，不開沙盒。
