# EasyNotes 架構與技術方案

Oct 1, 2026 · @Brian

EasyNotes 是個人使用的知識庫 App（不上架、不公開、不商業化）。核心只負責檔案、同步、索引與外掛註冊；Markdown、白板、PDF 手寫、CSV、Flashcards 都是編譯期外掛。所有資料都是開放格式的真實檔案，透過 Supabase 在 iOS、iPadOS、macOS 間同步，Claude Code 可以直接讀寫。

## 背景與目標

要解決的兩個問題：

- **知識分散**：筆記、白板、表格、卡片散落在不同 App，無法互相連結與搜尋。
- **檔案類型鎖定**：Apple Notes、Notion、RemNote 的資料鎖在專屬格式，離開 App 就難以使用。

定位：給自己用的「Apple Pencil 與 AI agent 版 Obsidian」。Obsidian 的開放檔案、Apple Notes 的輕量手感、GoodNotes 的 PDF 手寫，並讓 Claude Code 不經 MCP 或格式轉換就能直接讀寫整個知識庫。

| 項目 | 目標 |
| --- | --- |
| 平台 | iOS、iPadOS、macOS（單一 SwiftUI Multiplatform target） |
| 同步 | Supabase（Auth + Storage + Postgres + Realtime） |
| 檔案類型 | 以 `.md` 為核心；Whiteboard、PDF 手寫、CSV、Flashcards 為外掛 |
| 非功能 | App < 100 MB（預估 15–30 MB）、記憶體與耗電有預算、離線可用、同步可靠（見「非功能預算」） |
| 使用範圍 | 個人使用：不上架、不公開、不商業化（授權限制因此寬鬆，但仍優先選 MIT / BSD 套件） |
| Vault 位置 | macOS：\~/Documents/EasyNotes（可見、不開沙盒）；iOS：App 的 Documents（「檔案」App 可見） |

## 設計原則

1. **檔案即真相**：每筆筆記是磁碟上的一個檔案，資料庫只是可重建的索引。刪掉索引不會遺失任何內容。
2. **開放格式**：`.md`、`.excalidraw`、`.csv`、`.pdf` + 標註旁檔，都能被其他工具直接打開；App 不改寫使用者的格式，未知欄位原樣保留。
3. **本地優先**：所有操作先寫本地，離線完全可用；同步在背景進行。
4. **核心不認識檔案類型**：核心只有檔案（Vault）、同步、索引與外掛註冊。Markdown 也是外掛，和其他外掛走同一套介面。
5. **外掛依功能切分、編譯期組裝**：外掛只依賴 Core、彼此不依賴；用 WebView 或原生是外掛內部的實作選擇。
6. **原生外殼、合適的編輯面**：導覽、資料、同步、手寫用 Swift；有成熟套件的編輯面（CodeMirror 6、RevoGrid）用 WebView。
7. **為 Claude Code 優化**：格式讓 Claude 直接讀寫；外部修改即時偵測並同步；Vault 根目錄的 `CLAUDE.md` 說明慣例。

## 技術選型決策

決策：Swift 做外殼與資料層；Markdown 與 CSV 用 WebView（CodeMirror 6、RevoGrid）；手寫、白板、PDF 用原生（PencilKit、PDFKit、SwiftUI Canvas）。2026-10-01 修訂：不再使用 Excalidraw 的 Web runtime，只保留 .excalidraw 檔案格式，白板改為原生自建。Notion、Obsidian、Typora 的編輯器都是 Web 技術，流暢度取決於工程手法，而非原生與否。

### 考慮過的路線

| 路線 | 優點 | 缺點 | 結論 |
| --- | --- | --- | --- |
| A. Swift 外殼 + WebView 編輯器 | 原生手感 + Web 生態系 | 兩套技術棧、Bridge 複雜度 | **採用** |
| B. 純 Swift，捨棄 Excalidraw | 單一技術棧、最輕 | 自建即時預覽編輯器約佔整個 App 一半工程；失去白板生態 | 不採用 |
| C. Tauri / Capacitor 全 Web | 寫一次到處跑 | 外殼不原生，違背 Apple Notes 定位 | 不採用 |

### WebView 的取捨

| 優點 | 缺點 |
| --- | --- |
| 直接用 CodeMirror 6、RevoGrid、KaTeX、Mermaid | 每個 WebContent 程序約多 30–80MB 記憶體 |
| iOS 與 macOS 渲染一致 | 冷啟動約 100–300ms，需預熱 |
| 迭代快，可用 Safari Web Inspector 除錯 | Bridge 非同步、需序列化 |
| 打包在 App 內的 JS 可上架（App Store 禁止的是下載程式碼） | IME、選取、無障礙需額外調校；Pencil 延遲較高 |

切分原則：**內容編輯面且有成熟套件 → Web**；外殼、導覽、資料、同步、系統整合、手寫 → 原生。

2026-10-01 複核：**保留 WebView + Bridge，但只用在 Markdown 與 CSV 兩個外掛。** S1 已在實機驗證注音組字與效能；Bridge 不在打字路徑上；WebKit 是系統框架，不增加 App 體積。白板、PDF、複習介面、嵌入預覽與白板上的筆記卡片一律原生渲染，絕不為每張卡片開一個 WebView。只有在 iPhone 實測發現 WebView 記憶體導致背景被系統關掉時，才重新評估原生文字引擎（例如 STTextView）。

### Markdown 編輯器：CodeMirror 6，而非 TipTap

|  | TipTap (ProseMirror) | CodeMirror 6 |
| --- | --- | --- |
| 真相來源 | 自有文件樹，存檔時轉回 md | md 文字本身 |
| md 還原度 | 會正規化清單符號、空行、跳脫字元 | 原樣保留 |
| 中文 IME | contenteditable 在 iOS WebKit 組字問題較多 | 成熟 |
| 大檔案 | 全文件渲染 | 只渲染可見區域 |
| 實績 | Notion 類區塊編輯器 | Obsidian |

「檔案不被鎖」要求磁碟上是乾淨的 md，因此選 CodeMirror 6，用 decorations 做 Live Preview。

### 手寫：PencilKit，而非 MaLiang

|  | PencilKit | [MaLiang](https://github.com/Harley-xk/MaLiang) |
| --- | --- | --- |
| 維護 | Apple，每年更新 | 最後 release 2.9.2（2020-12），54 個 open issue |
| 延遲 | 最低（系統預測 + 低延遲渲染） | 自行 Metal 渲染，需自己調校 |
| 防誤觸、雙擊切換、Scribble | 內建 | 需自寫 |
| 筆刷 | 系統筆刷，自訂有限 | 可用材質自訂筆刷 |
| 平台 | 編輯畫布限 iOS/iPadOS；macOS 可顯示 | 僅 iOS，Swift 5.0 |
| 資料 | `dataRepresentation()` 為封閉格式，但 `PKStroke` 可讀出每個點 | 自有格式 |

筆記 App 重視延遲與系統整合多於自訂筆刷，選 PencilKit。存檔時把筆畫轉成 Excalidraw freedraw JSON，避開格式鎖定。

## 系統架構

&#91;embedded content: 系統分層 · UI 層、核心層、Supabase\]

**Vault 是唯一真相**，Index 與 Sync 都從它衍生。核心只透過 PluginRegistry 認識外掛；外掛的編輯器（不論 WebView 或原生）永遠不直接碰網路，讀寫檔案一律經過 Vault。

### 模組結構

```
Packages/
  EasyNotesCore/     核心（不認識任何檔案類型）
    EasyNotesCore    Vault、Index、Sync、DocumentKind 與 KindRegistry（無 UI 依賴，可單元測試）
    EasyNotesUI      PluginRegistry、EasyNotesPlugin、DocumentSession、EditorController、
                     WebEditorHost（預熱、Bridge、本地資源）、DesignSystem（tokens、共用元件）
  KindMarkdown/      .md：CodeMirror 6 編輯器（WebView）、Live Preview、Writing 模式
  KindWhiteboard/    .excalidraw：PencilKit 手寫層 + 原生結構元素層
  KindPDF/           .pdf + .pdf.ink 標註旁檔
  KindSheet/         .csv：RevoGrid 編輯器（WebView）
  Flashcards/        卡片解析、FSRS 排程、複習介面（不是檔案類型）
App/                 SwiftUI 外殼；啟動時把各外掛註冊進 PluginRegistry
web/                 WebView 外掛的 TypeScript 原始碼；每個外掛一個 entry，打包進各自的外掛
```

### 依賴規則

- **外掛只依賴 EasyNotesCore 與 EasyNotesUI**，外掛之間不互相 import。需要別的外掛的能力時，透過 Registry 查詢。例如白板要顯示 md 筆記卡片，就向 Registry 要 `.md` 的 PreviewProvider，而不是 import KindMarkdown。
- **Core 永遠不 import 外掛**；App target 負責組裝。
- **外掛是編譯期的 SPM 模組**，不在執行時期載入程式碼。
- **WebView 或原生是外掛內部的實作選擇**。WebView 外掛共用 EasyNotesUI 的 WebEditorHost，仍遵守「打字熱路徑不跨 Bridge」。
- **Markdown 也是外掛**，沒有特權通道，用來驗證外掛介面是否夠用。
- **卡片語法屬於 Vault 的 Markdown 方言**，所以語法標示由 Markdown 外掛負責；Flashcards 只負責解析、排程與複習。這樣不必在執行時期把 JS 擴充注入別的外掛。

### 擴充點

```swift
// EasyNotesCore：檔案類型（無 UI，可單元測試）
protocol DocumentKind {
    static var id: String { get }
    static var fileExtensions: [String] { get }
    static func template(title: String) -> Data
    static func index(_ data: Data, fileName: String) -> IndexEntry
    static func merge(base: Data?, local: Data, remote: Data) -> Data?  // nil = 衝突副本
    static func renameLinks(in data: Data, from: String, to: String) -> Data?  // 預設 nil = 沒有要改的連結
}

// EasyNotesCore：Vault、Index、Sync 只認識這張表（Sendable，啟動後不變）
struct KindRegistry {
    init(_ kinds: [any DocumentKind.Type]) throws  // 重複註冊同一副檔名 → 拋錯
    func kind(for path: String) -> (any DocumentKind.Type)?  // 未註冊 → nil
}

// EasyNotesUI：每個外掛的入口，App 啟動時依序呼叫
protocol EasyNotesPlugin {
    @MainActor static func register(in registry: PluginRegistry)
}

// EasyNotesUI：編輯器透過 environment 取得 Vault，由 App 的 VaultStore 實作
@MainActor protocol DocumentSession {
    func readData(_ path: String) -> Data
    func write(_ data: Data, to path: String)
    func openLink(_ target: String)
    func search(_ query: String)
}

// EasyNotesUI：VaultStore 透過它通知編輯器，不再直接呼叫 WebEditorHost
@MainActor protocol EditorController {             // 預設實作都不做事
    func attach(_ session: any DocumentSession)     // App 建立 VaultStore 後呼叫一次
    func flush() async                              // 改名、刪除、進背景前
    func externalChange(path: String, data: Data)   // 外部修改或同步
    func close(path: String)
    func linkTargetsChanged(_ names: [String])
}

// PluginRegistry（@MainActor）的擴充點；等第二個外掛真的需要時才抽出，不預先設計
registry.addKind(MarkdownKind.self, symbol: "doc.text", tint: .neutral)  // 第一個註冊的 Kind = [[連結]] 找不到時建立的類型；tint = 類型顏色
registry.addEditor(for: MarkdownKind.id) { path in MarkdownEditorView(path: path) }
registry.addNewFile("新筆記", kind: MarkdownKind.self, symbol: "square.and.pencil", shortcut: "n", defaultName: "未命名")
registry.addController(MarkdownEditor.shared)
registry.addMenu("格式", sections: [[...], [...]])          // App 以 Commands 呈現，最多 4 個頂層選單
registry.addImport("匯入 PDF…", kind: PDFKind.self, symbol: "doc.richtext", shortcut: "o")  // 新增選單的匯入；檔案複製進目前資料夾
registry.addPanel(id: "review", title: "複習", symbol: "rectangle.stack", badge: { dueCount }) { ReviewView() }  // 側邊欄項目
registry.kinds                                                // → KindRegistry，交給 VaultFS、VaultIndex
// 之後的 Phase：
registry.addIndexContributor(CardExtractor())                  // Flashcards：從 md 抽出卡片
registry.addPreview(for: MarkdownKind.id, MarkdownPreview())   // ![[x]] 嵌入、白板筆記卡片
```

2026-10-01 決定：Registry 分兩層。Core 只有無 UI 的 KindRegistry，給 Vault、Index、Sync 使用；PluginRegistry 需要 SwiftUI（addEditor 回傳 View），所以放在 EasyNotesUI。外掛不能 import App，因此 VaultStore 中 Markdown 專屬的邏輯（改名時更新連結、外部修改推給編輯器、自動完成清單）改走 DocumentKind.renameLinks 與 EditorController。

現況（2026-10-01）：Phase 1.5 的結構重構已完成，Core 不再包含任何檔案類型；`VaultIndex.clean()` 的片段清理仍是 Markdown 語法，第二個有文字的外掛需要時再抽成擴充點。

### Bridge 協定（Swift ⇄ WebView）

| 方向 | 訊息 | 時機 |
| --- | --- | --- |
| Swift → JS | `load({id, text})` | 開啟或切換筆記 |
| Swift → JS | `applyRemote({id, text})` | 同步拉到遠端變更 |
| Swift → JS | `exec({command})`、`setTheme` | 工具列、快捷鍵、深色模式 |
| JS → Swift | `ready` | bundle 載入完成（預熱結束） |
| JS → Swift | `changed({id, text})` | 停止輸入 300ms 或失焦 |
| JS → Swift | `openLink({target})` | 點擊 `[[連結]]` |

## 流暢編輯的工程手法

核心規則：**打字的熱路徑永遠不跨 Bridge**。對標 Obsidian、Typora 的手感，靠以下七項：

1. **編輯器自持狀態**：按鍵只在 JS 內處理；Swift 在停止輸入 300ms 或失焦時才收到變更，大檔案傳 diff 而非全文。
2. **單一預熱 WebView**：App 啟動即載入 bundle；切換筆記只換 `EditorState`，不重載頁面。每篇開過的筆記保留 state，切回瞬間完成且 undo 還在。
3. **增量解析 + 視窗渲染**：Lezer 增量解析，CodeMirror 6 只渲染可見行。
4. **Live Preview**：游標所在行顯示 md 語法，其餘行用 decorations 渲染為最終樣式。
5. **原生細節**：`-apple-system` 字型、Dynamic Type、深色模式；鍵盤工具列用原生 `inputAccessoryView`；macOS 快捷鍵走原生選單再轉發；圖片由 `WKURLSchemeHandler` 從本地讀取。
6. **I/O 不擋主執行緒**：atomic write、`NSFileCoordinator` + 檔案監看處理外部修改、索引在背景更新。
7. **啟動即開上一篇**：先顯示快取內容，再載入編輯器。

## 外掛功能設計

每個外掛決定自己的格式、編輯器與合併策略。「不做」的項目是刪減後的決定，不是遺漏。

| 外掛 | 格式 | 編輯器 | 同步合併 |
| --- | --- | --- | --- |
| Markdown | `.md` + YAML frontmatter | CodeMirror 6（WebView） | diff3 三方合併（以行為單位） |
| Whiteboard | `.excalidraw`（官方 JSON） | PencilKit + SwiftUI Canvas（原生） | 依元素 `id` + `version` |
| PDF | `.pdf`（不改動）+ `.pdf.ink`（JSON） | PDFKit + PencilKit（原生） | PDF 不合併；旁檔依頁 + 元素 `id` |
| Sheets | `.csv`；欄寬等放 `.csv.meta.json` | RevoGrid（WebView） | diff3（以列為單位） |
| Flashcards | 卡片寫在 `.md`；紀錄 `.easynotes/srs/<deviceId>.jsonl` | 原生複習介面 | 卡片跟著 md；紀錄各裝置各寫，永不衝突 |

### Markdown

- **做**：Live Preview、`[[連結]]` + 反向連結、`[[` 自動完成、連結改名、標籤、FTS5 搜尋、`![[x.excalidraw]]` / `![[x.csv]]` 嵌入預覽、卡片語法標示、Writing 模式（專注、打字機捲動、字數）。
- **實作**：CM6 + Lezer 增量解析；單一預熱 WebView，切換筆記只換 `EditorState`；Bridge 協定見上文。
- **Phase 2 必做**：diff3 三方合併。非重疊修改自動合併，重疊才產生衝突副本。編輯中收到遠端變更時，用 `applyRemote` 套用到 CM6，保留游標與 undo。

### Whiteboard（`.excalidraw`）

- **做**：無限畫布；手寫層（筆、橡皮擦、套索）；結構層 6 種元素：rectangle、ellipse、arrow（可綁定到形狀）、text、image、frame；選取、移動、縮放。
- **不做**：Excalidraw Web runtime；手寫辨識與搜尋索引（手寫多為 brainstorming，不是主要筆記）；即時協作。
- **實作**：下層 `PKCanvasView` 處理手寫，存成 freedraw 元素（已有 `ExcalidrawInk` 轉換）。上層 SwiftUI Canvas 繪製結構元素並處理手勢，序列化成標準 Excalidraw elements。未知元素與欄位原樣寫回，檔案可在 excalidraw.com 開啟。
- **平台**：`PKCanvasView` 只有 iOS/iPadOS，macOS 上手寫只能顯示，結構元素可編輯。

#### 筆記卡片放進白板（Heptabase / Obsidian Canvas 式，選做）

難度中等，前提是白板結構層已完成。

- **格式**：用一個 rectangle 元素代表卡片，`link` 設為 `[[筆記]]`，`customData.easynotes.file` 記錄檔案路徑（改名時由連結改名流程一併更新）。在 excalidraw.com 上會優雅降級成一個帶連結的框。
- **顯示**：白板向 Registry 要 `.md` 的 PreviewProvider，由 Markdown 外掛產生唯讀預覽（標題 + 前幾段），外掛之間仍不互相依賴。
- **互動**：點卡片在側邊面板開啟完整編輯器。不做畫布內直接編輯：縮放中的畫布上要同時跑多個 CM6 編輯器，成本高、收益小。
- **互通**：需要與 Obsidian Canvas 互通時，另做 JSON Canvas（`.canvas`）匯出即可，不必多維護一種畫布格式。

### PDF 手寫與標註

- **做**：開啟 PDF；原子筆、螢光筆、橡皮擦、套索選取、便利貼；匯出合併標註後的 PDF。
- **不做**：插入空白頁、頁面縮圖與重排、PDF 文字搜尋、手寫辨識。
- **實作**：`PDFView` + `PDFPageOverlayViewProvider`，每個可見頁面疊一個 `PKCanvasView`，離開畫面就回收，避免大檔案吃光記憶體。`drawingPolicy = .pencilOnly`，手指捲動與縮放、Pencil 書寫。
- **格式**：原始 PDF 不改動。標註存在 `<檔名>.pdf.ink`（JSON）：`pdfHash` + 依頁碼分組的 Excalidraw elements。螢光筆 = 半透明 freedraw，便利貼 = 有背景色的 text 元素，沿用 Whiteboard 的筆畫轉換。檔案樹中隱藏 `.pdf.ink`。
- **平台**：macOS 只能顯示標註。

### Sheets（`.csv`）

- **做**：RevoGrid 編輯（修改儲存格、增刪列欄、排序與篩選檢視）；欄寬、凍結欄等顯示設定存 `.csv.meta.json`；在 md 內 `![[x.csv]]` 嵌入表格預覽。
- **不做**：公式、多工作表、圖表。CSV 只存資料；需要試算表功能時用「用其他 App 開啟」交給 Numbers / OnlyOffice。
- **實作**：Swift 端做 RFC 4180 解析與序列化，WebView 只拿列資料。未修改的列逐位元組寫回（引號風格、換行符不變），讓 diff 與合併保持乾淨。

### Flashcards

- **語法**（類 RemNote）：`光合作用發生在 :: 葉綠體 ^c-a1b2` 單向、`中文 ;; Chinese ^c-c3d4` 雙向、`粒線體是 {{細胞的發電廠}} ^c-e5f6` 克漏字。行尾 `^id` 讓卡片在編輯後仍保有身分，缺少時由 App 自動補上。
- **對齊 Anki**：卡片狀態（New / Learning / Review / Relearning）、learning 與 relearning steps、四鍵（Again / Hard / Good / Easy）、desired retention、每日新卡與複習上限，預設值與 Anki 相同。
- **排程**：不自寫演算法。排程用 swift-fsrs（採用前確認版本跟上 FSRS 最新版）；參數優化用 fsrs-rs（Anki 本身使用的函式庫），透過 UniFFI 包成 Swift。
- **複習紀錄**：`.easynotes/srs/<deviceId>.jsonl`，只由該裝置追加。欄位對齊 Anki 的 `revlog`（`id` 毫秒時間戳、`cid`、`ease`、`ivl`、`lastIvl`、`time`、`type`），卡片狀態由重播所有裝置的紀錄算出，不另存。
- **牌組**：資料夾或標籤。
- **互通**：匯出 TSV 給 Anki 匯入；匯入 Anki `.apkg`（SQLite）與複習歷史為選做。

### 跨外掛功能

- `[[筆記]]` 連結；`![[圖.excalidraw]]`、`![[表.csv]]` 在 md 內嵌入預覽，預覽由各外掛向 Registry 註冊的 PreviewProvider 提供。
- 每個 `DocumentKind` 的 `index()` 抽出純文字與連結，所以白板內的文字元素也能搜尋、也會出現在反向連結（手寫筆畫不索引）。
- App 設定放 `.easynotes/`（類似 `.obsidian/`），跟著 Vault 同步。

## 同步設計

同步層只看 file id、path、內容 hash 與版本，不認識檔案類型；合併交給各 `DocumentKind`。現況：只建立了 Supabase client（`App/Sync/Supabase.swift`）；Phase 2a 已完成 Core 的 Diff3、SyncEngine、SyncState（以假 backend 測試），Phase 2b 已完成 migration 與 SupabaseSync（對本地 Supabase 的整合測試通過），Phase 2c 已接上 App（登入、排程、Realtime、狀態 UI、最近刪除），整合驗收以 Mac App + iOS 模擬器進行。

三個關鍵決定：

1. **穩定 file id**：檔案身分是 id，path 只是屬性。改名與搬移只更新 path，不變成「刪一個、新增一個」，歷史與合併基準都保留。
2. **版本檢查在伺服器端**：用 Postgres function（RPC）在一個交易內比對並遞增 version，兩台裝置同時上傳也不會互相覆蓋。
3. **三方合併在 Phase 2 一併完成**：Markdown 的 diff3 是同步的必要條件。Mac 上 Claude Code 寫檔、iPad 同時在編輯是常態，只有衝突副本不夠用。

2026-10-01 實作決定（Phase 2 開工前）：

- **同步引擎在 Core，網路在 App**：`SyncEngine`、`sync.sqlite`、上傳佇列放 EasyNotesCore，只依賴 `SyncBackend` 協定；獨立套件 `Packages/SupabaseSync` 的 `SupabaseBackend` 實作它（依賴 Core + supabase-swift，含對本地 Supabase 的 RPC 併發與 RLS 整合測試），App 只負責組裝。Core 不 import supabase-swift，同步引擎用記憶體內的假 backend 做單元測試。
- **diff3 是 Core 的通用工具**：以行為單位的三方文字合併，不認識檔案類型。Markdown 與 Sheets 的 `merge` 都呼叫它；外掛不能互相 import，所以放 Core。
- **登入用 Sign in with Apple**：Supabase Auth 的 Apple provider，原生 ID token 流程（AuthenticationServices），不需要網頁轉址。
- **Migration 放 repo 的 `supabase/migrations/`**：RPC 併發與 RLS 測試在本地 Supabase（CLI + Docker）跑，通過後用 `supabase db push` 套到雲端專案。

### Supabase 資料表

```sql
create table files (
  id          uuid primary key,          -- 穩定 file id，由建立檔案的裝置產生
  user_id     uuid not null references auth.users,
  path        text not null,             -- vault 內相對路徑，只是屬性
  hash        text not null,             -- SHA-256 of content
  size        bigint not null,
  version     bigint not null,           -- 只由 commit_file 遞增
  deleted     boolean not null default false,
  device_id   text not null,
  updated_at  timestamptz not null default now()
);
create unique index files_live_path on files (user_id, path) where not deleted;
-- RLS：user_id = auth.uid()；Storage bucket 同樣以 user_id 限制

-- 一個交易內：比對 base_version、寫入、遞增 version
-- 回傳新 version；回傳 null = 遠端已變，需要合併
create function commit_file(p_id uuid, p_base_version bigint, p_path text,
  p_hash text, p_size bigint, p_deleted boolean, p_device text) returns bigint;
```

檔案內容以 hash 為 key 存在 Storage（`vault/<user_id>/<hash>`）：只增不覆寫、自動去重、舊版本可當歷史，上傳中斷重傳也不會損壞資料。publishable key 可以放在 repo，前提是所有資料表與 bucket 都開了 RLS。

### 本地同步狀態

- `.easynotes/sync.sqlite`（不同步）：每個檔案一列，`file_id`、`path`、`base_version`、`base_hash`、上傳佇列狀態。
- `.easynotes/cache/base/<hash>`：上次同步的內容，當作三方合併的 base。
- App 內改名直接更新 path；外部工具（Finder、Claude Code 的 `mv`）改名時，VaultWatcher 會看到「刪除 + 新增」，若兩者 hash 相同就推斷為改名並保留 file id。推斷失敗最多失去歷史，不會遺失內容。

### 流程

1. **本地變更**：寫入檔案（App 內或 Claude Code 等外部工具）→ VaultWatcher 比對 hash → 更新索引 → 進入上傳佇列。
2. **上傳**：先傳內容到 Storage，再呼叫 `commit_file(id, base_version, …)`。回傳 null 代表遠端已變，進入合併。
3. **拉取**：Realtime 訂閱 `files` 變更；回到前景時補拉 `updated_at` 大於上次游標的列。只有 path 變了 = 改名，直接搬移本地檔案。
4. **合併**：下載遠端內容，連同本地與 base 交給 `DocumentKind.merge`。成功 → 寫回本地並上傳合併結果；回傳 nil → 產生 `筆記 (衝突 iPad 2026-10-01).md`。正在編輯的文件透過編輯器套用遠端變更（Markdown 用 `applyRemote`）。
5. **刪除**：軟刪除（`deleted = true`），保留 30 天。內容留在 Storage（只增不覆寫），所以 30 天內都能還原。
6. **還原**：同步面板的「最近刪除」列出 30 天內刪除、本地也不存在的檔案（`SyncBackend.deletedFiles`）。還原 = 下載該 hash 的內容寫回原路徑（被佔用時改用衝突副本的命名），再以同一個 file id 提交 `deleted = false`，歷史與合併基準都保留。
7. **清除**：pg_cron 每天刪掉 `deleted` 超過 30 天的列。Storage 的內容不刪（內容定址、可能被其他版本共用），之後需要時再做垃圾回收。

### 各類型的合併策略

| 類型 | 策略 |
| --- | --- |
| `.md` | diff3，以行為單位；重疊修改 → 衝突副本 |
| `.excalidraw`、`.pdf.ink` | 依元素 `id` + `version` 合併（與 Excalidraw 官方協作相同） |
| `.csv` | diff3，以列為單位 |
| `.easynotes/srs/*.jsonl` | 每台裝置只寫自己的檔案，天然無衝突 |
| 其他（`.pdf`、圖片） | 內容不同 → 衝突副本 |

## Claude Code 整合

- **Vault 根目錄的 `CLAUDE.md`**：說明 frontmatter 規範、卡片語法、資料夾慣例，以及不要手動修改的檔案（`.easynotes/srs/*.jsonl`、`.easynotes/cache/`、`sync.sqlite`）。
- **外部修改是一等公民**：Claude Code 寫檔與 App 內編輯走同一條路徑（監看 → 索引 → 上傳）。
- **產生卡片只需要寫 md**：Claude 寫入 `::` 語法即可，`^id` 由 App 補上。
- **手寫不為 Claude 做辨識**：手寫是 brainstorming，不是知識庫的主體。

## 非功能預算

每個 Phase 結束時用 Release build 量測一次；超出預算就先修，再進入下一個 Phase。

| 項目 | 預算 | 量測方式 |
| --- | --- | --- |
| App 大小 | < 100 MB（預估 15–30 MB） | Release build 的 `.app` 大小 |
| 記憶體 | iPhone 開著一篇 md 閒置時，App + WebContent 合計 < 150 MB | Xcode Memory gauge、Instruments Allocations |
| 耗電 | 閒置時 Energy gauge 為 Low；後台不保持網路連線 | Xcode Energy gauge、Instruments |
| 切換筆記 | < 50 ms | S1 的測量方式 |

### App 大小組成（預估）

| 組成 | 大小 |
| --- | --- |
| 目前 Debug build（實測，尚未包含 Supabase） | 1.8 MB |
| supabase-swift | 約 3–8 MB |
| CM6 bundle（實測） | 0.5 MB |
| RevoGrid bundle | 約 0.5–1 MB |
| fsrs-rs 靜態函式庫（UniFFI） | 約 2–5 MB |
| PencilKit、PDFKit、WebKit | 0（系統框架） |

Vault 內容存在 Documents，不算在 App 本體大小內。

### 記憶體做法

- **Markdown**：單一共用、預熱的 WebView；`EditorState` 只保留最近 20 篇（LRU），收到記憶體警告時清掉不在畫面上的。
- **CSV**：RevoGrid 的 WebView 開檔時才建立、關閉後釋放，不常駐。
- **PDF**：只為可見頁面建立 `PKCanvasView`，翻走就回收；每頁筆畫需要時才載入。
- **圖片**：用 ImageIO 依顯示尺寸產生縮圖，不解碼原圖。
- **嵌入預覽與筆記卡片**：原生渲染，結果快取成 SVG / PNG 存在磁碟。

### 耗電做法

- **Realtime**：只在前景保持連線，進背景就斷開；回到前景時補拉。不註冊背景更新任務（`BGAppRefreshTask`）。
- **上傳**：同步佇列合併短時間內的連續變更，閒置幾秒後才批次上傳。
- **Hash**：只在 mtime 或大小改變時計算；大型 PDF 以串流方式計算。
- **檔案監看**：FSEvents 只重掃事件帶來的路徑。現況是每次事件都對整個 Vault 做 stat，Claude Code 一次改很多檔案時會重複觸發。
- **無輪詢**：Swift 端沒有計時器輪詢；JS 端不跑 interval 或 rAF 迴圈；白板只在內容變動時重繪，不用 `TimelineView`。
- **執行緒**：索引與 hash 用 `.utility` QoS。

### 驗收情境（Instruments）

1. 連續打字 5 分鐘（記憶體不持續成長、CPU 在停止輸入後回到閒置）
2. PDF 快速翻完 200 頁（記憶體穩定）
3. Claude Code 一次修改 50 個檔案（只重新索引這 50 個，不重掃整個 Vault）