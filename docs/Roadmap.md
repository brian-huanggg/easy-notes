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
- [ ] 整合：App 開著時用 Claude Code 修改、搬移檔案 → 數秒內出現在 iPad，file id 不變
- [ ] 整合：上傳中強制結束 App → 重啟後自動補傳，無資料遺失
- [ ] 整合：刪除後 30 天內可還原
- [ ] 耗電：進背景後沒有網路連線；連續打字 1 分鐘只產生少數幾次上傳
- [ ] 基準線符合非功能預算（含 supabase-swift 後的 App 大小）

## Phase 3 — Flashcards

目標：在 md 內寫卡片，用與 Anki 相同的 FSRS 排程複習；多裝置紀錄自動合併。

- [ ] 卡片解析（`::`、`;;`、`{{}}`、`^id`），缺 `^id` 時自動補上
- [ ] Markdown 外掛的卡片語法標示
- [ ] 接入 swift-fsrs 排程；卡片狀態、steps、四鍵、desired retention 對齊 Anki
- [ ] 複習紀錄 jsonl（欄位對齊 Anki revlog）與重播
- [ ] 原生複習介面、牌組（資料夾 / 標籤）、每日上限
- [ ] TSV 匯出給 Anki
- [ ] fsrs-rs 參數優化（UniFFI）
- [ ] 選做：匯入 Anki `.apkg` 與複習歷史

驗收測試：

- [ ] 解析器 fixture 測試：三種語法、程式碼區塊內不視為卡片、編輯卡片文字後 `^id` 不變
- [ ] 排程結果與 fsrs-rs / py-fsrs 參考向量一致
- [ ] 重播決定性：同一組紀錄在不同裝置算出相同卡片狀態
- [ ] 多裝置：Mac 與 iPad 各自複習後同步，到期日正確
- [ ] 手動：TSV 匯入 Anki 後卡片正確

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
