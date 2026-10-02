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
| 發佈 | iOS / iPadOS：TestFlight（`upload-testflight.sh`）；macOS：DMG（`make-dmg.sh`）。macOS 不開沙盒，所以不能走 TestFlight / Mac App Store；App Store Connect 關閉「iPad App 可在 Mac 上使用」，避免 Mac 裝到 iPad 版（沙盒 Vault、iOS UI） |

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
  ExcalidrawKit/     共用函式庫（不是外掛、不註冊任何東西）：Excalidraw 元素模型、合併、
                     PencilKit ⇄ freedraw 轉換、幾何與 CoreGraphics 渲染器（Phase 5 從 KindWhiteboard 抽出）
  KindWhiteboard/    .excalidraw：PencilKit 手寫層 + 原生結構元素層
  KindPDF/           .pdf + .pdf.ink 標註旁檔：PDFKit + 每頁 PencilKit 疊層
  KindSheet/         .csv、.tsv：RevoGrid 編輯器（WebView）
  Flashcards/        卡片解析、FSRS 排程、複習介面（不是檔案類型）
App/                 SwiftUI 外殼；啟動時把各外掛註冊進 PluginRegistry
web/                 WebView 外掛的 TypeScript 原始碼；每個外掛一個 entry，打包進各自的外掛
```

### 依賴規則

- **外掛只依賴 EasyNotesCore、EasyNotesUI 與共用函式庫**，外掛之間不互相 import。需要別的外掛的能力時，透過 Registry 查詢。例如白板要顯示 md 筆記卡片，就向 Registry 要 `.md` 的 DocumentPreviewProvider，而不是 import KindMarkdown。
- **共用函式庫**（目前只有 `ExcalidrawKit`）：兩個以上外掛需要同一份格式程式時才抽出。它不是外掛：不依賴 EasyNotesUI 的 Registry、不註冊 Kind / 編輯器 / 選單，只提供模型、轉換與渲染；也不依賴任何外掛。2026-10-02 決定（Phase 5）：PDF 標註需要白板的元素模型、合併、筆畫轉換與渲染器，複製會讓兩份程式漂移，併進 KindWhiteboard 會讓 PDF 無法獨立移除，所以抽成 `ExcalidrawKit`。
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
    static func setPinned(_ pinned: Bool, in data: Data) -> Data?  // 預設 nil = 不支援釘選
    static func companionOf(_ path: String) -> String?  // 預設 nil；伴隨檔回傳主檔路徑（Phase 5：x.pdf.ink → x.pdf）
}

// index() 的結果；icon、pinned、summary 由外掛決定，Core 只存不解讀
struct IndexEntry { title, plainText, links, tags, icon: String?, pinned: Bool, summary: String? }

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
    func modified(_ path: String) -> Date?          // 文件頭的「N 分鐘前編輯」
    func importAttachment(_ url: URL) async -> String?  // 複製到 Vault 的 `附件/`，回傳 Vault 內路徑
    var resourceReader: @Sendable (String) async -> Data? { get }  // `vault://` 圖片，背景讀取
}

// EasyNotesUI：VaultStore 透過它通知編輯器，不再直接呼叫 WebEditorHost
@MainActor protocol EditorController {             // 預設實作都不做事
    func attach(_ session: any DocumentSession)     // App 建立 VaultStore 後呼叫一次
    func flush() async                              // 改名、刪除、進背景前
    func externalChange(path: String, data: Data)   // 外部修改或同步
    func close(path: String)
    func linkTargetsChanged(_ targets: [LinkTarget])  // [[ 自動完成與連結卡片：名稱、kind、摘要、mtime、tint、圖示
}

// PluginRegistry（@MainActor）的擴充點；等第二個外掛真的需要時才抽出，不預先設計
registry.addKind(MarkdownKind.self, name: "筆記", symbol: "doc.text", tint: .neutral)  // 第一個註冊的 Kind = [[連結]] 找不到時建立的類型；name = 篩選 chip；tint = 類型顏色
registry.addPreview(for: MarkdownKind.id, MarkdownPreview())   // 列表卡片縮圖（原生渲染）；`DocumentPreview.image`（PNG）也用於 ![[x]] 嵌入（`embed://`）、白板筆記卡片
registry.addEditor(for: MarkdownKind.id) { path in MarkdownEditorView(path: path) }
registry.addNewFile("新筆記", kind: MarkdownKind.self, symbol: "square.and.pencil", shortcut: "n", defaultName: "未命名")
registry.addController(MarkdownEditor.shared)
registry.addMenu("格式", sections: [[...], [...]])          // App 以 Commands 呈現，最多 4 個頂層選單
registry.addImport("匯入 PDF…", kind: PDFKind.self, symbol: "doc.richtext", shortcut: "o")  // 新增選單的匯入；檔案複製進目前資料夾
registry.addPanel(id: "review", title: "複習", symbol: "rectangle.stack", badge: { dueCount }) { ReviewView() }  // 側邊欄項目
registry.kinds                                                // → KindRegistry，交給 VaultFS、VaultIndex
registry.addIndexContributor(CardIndexer())                    // Flashcards：從 md 抽出卡片，存成索引的 records
registry.addContentFixer(CardIDFixer())                         // Flashcards：替缺少 ^id 的卡片補上 id
registry.addVaultGuide(guide)                                   // Vault 根目錄 CLAUDE.md 的一節（Markdown：筆記慣例；Flashcards：卡片語法）
registry.addSyncedMetaFolder("srs")                             // Flashcards：`.easynotes/srs/` 參與同步（其餘 `.easynotes/` 不同步）

// EasyNotesUI：不是編輯器的外掛（Flashcards）也透過 DocumentSession / EditorController 存取 Vault（3c）
session.vault                       // VaultFS：讀寫外掛自己的 `.easynotes/<name>/`
session.index                       // VaultIndex?：records、檔案標籤
session.open(path, line: 84)        // 開啟檔案並捲到該行（複習時的「編輯筆記」）
session.metaChanged()               // 外掛寫了同步的 meta 檔案 → 排程上傳
controller.vaultChanged(paths)      // 索引更新後（App 內編輯、外部修改、同步，含 `.easynotes/srs/` 的同步下載）
controller.moved(from:, to:)        // App 內改名或搬移（檔案或資料夾）
controller.reveal(path:, line:)     // Markdown：捲到該行並把游標放在行首

// EasyNotesCore：這台裝置的身分，存在 `.easynotes/device-id`（不同步）；SyncEngine 與 Flashcards 共用
vaultFS.deviceID() -> String
```

2026-10-02 決定（3c）：

- 不新增「服務」型的擴充點：Flashcards 註冊一個 `EditorController`（`ReviewStore`），在 `attach` 取得 session，靠 `vaultChanged` / `moved` 得知變動。`EditorController` 的意義從「編輯器」放寬為「App → 外掛的通知」。
- `vaultChanged(paths)` 只帶路徑，外掛自己決定要不要重讀（Flashcards：md 變動 → 重讀卡片 records；`.easynotes/srs/` 變動 → 重讀紀錄，只重播有新紀錄的卡片）。
- `open(path, line:)` 由 App 導覽到檔案後呼叫各 controller 的 `reveal`；不是打字熱路徑，可以跨 Bridge。
- `VaultIndex.fileTags()`：路徑 → 標籤（卡片的標籤 = 所在筆記的標籤）。

2026-10-02 決定（3b）：

- `addSyncedMetaFolder`：`.easynotes/` 預設不同步（索引、快取、同步狀態都是本機的）。外掛需要同步自己的資料時，註冊 `.easynotes/` 下的子資料夾，App 把清單交給 `SyncEngine`。用白名單而不是「`.easynotes/` 除了 cache 都同步」，避免 `seeded` 之類的本機標記被帶到其他裝置。這些檔案沒有註冊的 `DocumentKind`，合併時視為不透明檔案（內容不同 → 衝突副本）；外掛要自己設計成不會衝突（例如每台裝置只寫自己的檔案）。
- `VaultFS.deviceID()`：第一次呼叫時產生 UUID 寫入 `.easynotes/device-id`（不同步）。舊版存在 `sync.sqlite` 的 device 會先搬過來，id 不變。檔案被刪掉只會換一個新 id，用到 id 的資料（例如複習紀錄）多出一個新檔案，不會遺失。

2026-10-02 決定（3a）：

- `IndexContributor`（Core，無 UI）：外掛從檔案內容抽出自己的資料，Core 存在通用的 `records(contributor, path, key, value)` 表，`value` 是外掛自訂的 JSON 字串，Core 不解讀。外掛的 `version` 改變時整個索引重建。查詢只有「某 contributor 的全部 records」與「某 key 出現在哪些檔案」，複雜的查詢由外掛在記憶體中做（個人 Vault 的卡片數量級是數千）。
- `ContentFixer`（Core，無 UI）：外掛在背景改寫檔案內容，App 寫回後照一般路徑索引與同步。App 只對**本機產生**的變動（App 內編輯、外部工具）呼叫，不處理同步拉下來的內容；**開啟中的檔案不改寫**，離開該檔案後才處理，所以不會在打字或注音組字中插入文字，也不必跨 Bridge。連續變動合併後（約 1.5 秒）才執行，讓 Claude Code 搬移內容時兩個檔案都寫完再判斷。
- `addVaultGuide`：Vault 根目錄沒有 `CLAUDE.md` 時，App 以各外掛提供的段落建立它；已存在就不改寫（使用者可以自行編輯）。

2026-10-01 決定：Registry 分兩層。Core 只有無 UI 的 KindRegistry，給 Vault、Index、Sync 使用；PluginRegistry 需要 SwiftUI（addEditor 回傳 View），所以放在 EasyNotesUI。外掛不能 import App，因此 VaultStore 中 Markdown 專屬的邏輯（改名時更新連結、外部修改推給編輯器、自動完成清單）改走 DocumentKind.renameLinks 與 EditorController。

2026-10-02 決定（Phase 4）：

- `DocumentPreview`（EasyNotesUI）新增 `image: Data?`（PNG）：圖形類外掛（白板、之後的 PDF）在 `makePreview` 中於背景畫出縮圖，依 hash 快取成 `<hash>.png`（與 `<hash>.json` 同資料夾，JSON 只記 `hasImage`，不放 base64）；Core 不認識圖的內容。白板縮圖的預設白色背景畫成透明，深色模式由顯示端反相（`invert` + `hue-rotate(180deg)`，與 Excalidraw 深色主題相同）。
- `embed:///<Vault 相對路徑>`（每段 percent-encode，與 `vault://` 相同）：WebEditorHost 新增的 `WKURLSchemeHandler`，經 `DocumentSession.embedImageReader`（App 的 VaultStore 實作，預設回傳 nil）回傳該檔案預覽的 `image`（依內容 hash 快取，檔案沒有註冊預覽或沒有圖時回 404）。Markdown 的 `![[x.excalidraw]]` 只放 `<img src="embed://…?h=<hash>">`，不經 Bridge；hash 變了 URL 就變，WebView 自動重新載入。Phase 6 的 `![[x.csv]]` 沿用同一個 scheme。

2026-10-02 決定（2.5c）：`DocumentPreviewProvider` 分兩段。`makePreview(Data) -> DocumentPreview` 在背景執行，結果可序列化，依內容 hash 快取在 `.easynotes/cache/preview/<kind>-v<version>/<hash>.json`；`view(_:)` 在主執行緒用原生 SwiftUI 渲染。沒有註冊預覽的類型顯示骨架佔位。

現況（2026-10-01）：Phase 1.5 的結構重構已完成，Core 不再包含任何檔案類型；`VaultIndex.clean()` 的片段清理仍是 Markdown 語法，第二個有文字的外掛需要時再抽成擴充點。

### Bridge 協定（Swift ⇄ WebView）

| 方向 | 訊息 | 時機 |
| --- | --- | --- |
| Swift → JS | `load({id, text, meta})` | 開啟或切換筆記；`meta.modified` 給文件頭 |
| Swift → JS | `applyRemote({id, text})`、`setMeta` | 同步拉到遠端變更、寫入後更新編輯時間 |
| Swift → JS | `exec({command, arg})` | 工具列、快捷鍵 |
| Swift → JS | `setLinkTargets(targets)` | 索引變更（自動完成、連結卡片） |
| JS → Swift | `ready` | bundle 載入完成（預熱結束） |
| JS → Swift | `changed({id, text})` | 停止輸入 300ms 或失焦 |
| JS → Swift | `openLink({target})`、`openTag({tag})` | 點擊 `[[連結]]`、`#標籤` |
| JS → Swift | `pickCover`、`pickIcon` | 文件頭的更換封面 / 圖示（原生 UI 處理，寫回 frontmatter） |

主題不經 Bridge：`ThemeCSS.stylesheet()` 由 WebEditorHost 以 user script 在頁面載入前注入，深淺色由 `prefers-color-scheme` 切換。圖片由 `vault://<Vault 相對路徑>`（`WKURLSchemeHandler`）讀取，只允許 Vault 內路徑；`![[x.excalidraw]]` 等嵌入預覽由 `embed://<Vault 相對路徑>` 提供（Phase 4，見「擴充點」）。文件 icon 為 SF Symbol（frontmatter `icon: sf:map`）時，經 `symbol:///<名稱>` 由 Swift 畫成 PNG，CSS 當 mask 上色。

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
| Whiteboard | `.excalidraw`（官方 JSON） | PencilKit + CALayer 結構層（原生） | 依元素 `id` + `version` |
| PDF | `.pdf`（不改動）+ `.pdf.ink`（JSON，伴隨檔） | PDFKit + 每頁 PencilKit 疊層（原生） | PDF 不合併；旁檔依頁 + 元素 `id` |
| Sheets | `.csv`、`.tsv`；欄寬等放 `.csv.meta.json` | RevoGrid（WebView） | diff3（以記錄為單位，同一記錄再以儲存格合併） |
| Flashcards | 卡片寫在 `.md`；紀錄 `.easynotes/srs/<deviceId>.jsonl`；設定 `.easynotes/srs/<deviceId>.config.json` | 原生複習介面 | 卡片跟著 md；紀錄與設定都是各裝置各寫，永不衝突；設定以欄位 LWW 合成 |

### Markdown

- **做**：Live Preview、`[[連結]]` + 反向連結、`[[` 自動完成、連結改名、標籤、FTS5 搜尋、`![[x.excalidraw]]` / `![[x.csv]]` 嵌入預覽、卡片語法標示、Writing 模式（專注、打字機捲動、字數）。
- **實作**：CM6 + Lezer 增量解析；單一預熱 WebView，切換筆記只換 `EditorState`；Bridge 協定見上文。
- **Phase 2 必做**：diff3 三方合併。非重疊修改自動合併，重疊才產生衝突副本。編輯中收到遠端變更時，用 `applyRemote` 套用到 CM6，保留游標與 undo。

### Whiteboard（`.excalidraw`）

- **做**：無限畫布；手寫層（筆、橡皮擦、套索）；結構層 6 種元素：rectangle、ellipse、arrow（可綁定到形狀）、text、image、frame；選取、移動、縮放。
- **不做**：Excalidraw Web runtime；手寫辨識與搜尋索引（手寫多為 brainstorming，不是主要筆記）；即時協作。
- **實作**：`PKCanvasView` 處理手寫，存成 freedraw 元素（已有 `ExcalidrawInk` 轉換）。結構元素由 UIKit / AppKit view 繪製（見下方 2026-10-02 決定），序列化成標準 Excalidraw elements。未知元素與欄位原樣寫回，檔案可在 excalidraw.com 開啟。
- **平台**：`PKCanvasView` 只有 iOS/iPadOS，macOS 上手寫只能顯示，結構元素可編輯。

2026-10-02 決定（Phase 4 開工前）：

- **維持原生，不用 Excalidraw Web runtime**：Excalidraw 每一筆都送出整個場景，放在 WebView 會讓 Pencil 輸入跨 Bridge；Pencil 延遲、bundle 大小與多一個 WebContent process 也都不划算。需要 Excalidraw 的進階功能時用「用其他 App 開啟」或 excalidraw.com。
- **結構層用 layer，不用 SwiftUI Canvas**：每個元素一個 `CAShapeLayer` / `CATextLayer`（只建立畫面內的元素），平移與縮放交給 Core Animation；SwiftUI Canvas 在縮放時每一幀整個重畫，1,000 個元素做不到流暢。結構層放在 `PKCanvasView` 底下，跟著它的 `contentOffset` / `zoomScale` 移動；縮放結束時重設 `contentsScale` 讓線條清晰。Spike S3（iPad Air M1 實機）確認可行，實作規則：
  - 結構層的 transform 在 `scrollViewDidScroll` / `DidZoom` 中同步設定（螢幕座標 = 畫布座標 × zoom − contentOffset），與 PencilKit 在同一個 CATransaction 提交，不會落後一幀。
  - **關閉縮放回彈**（`bouncesZoom = false`）：回彈是 Core Animation 動畫，期間 scroll view 不會每幀回呼，結構層直接跳到終點、筆畫還在動畫中，兩者會對不上。
  - **點陣倍率跟著縮放**（0.25…4）：縮放中不重新點陣化既有的 layer，新建的 layer 用目前倍率；縮放結束後分批重新點陣化。建立 layer 與重新點陣化每幀最多約 120 個，剩下的交給之後的幀。
  - **文字 layer 關閉 `contents` 動作**：文字是點陣 `contents`，預設換內容時淡入淡出 0.25 秒，舊點陣以新倍率顯示會成為放大 / 縮小的殘影。改 `contentsScale` 後在同一個 transaction 內 `displayIfNeeded()`。`CAShapeLayer` 是向量，沒有這個問題。
  - 1,000 個元素在 60Hz 機型維持 60 FPS；10,000 個元素降到約 30 FPS（縮小時全部在畫面內），需要 LOD（縮放倍率低時改畫點陣快照）。
- **疊放順序**：編輯器中手寫一律在結構元素之上（`PKCanvasView` 是獨立的一層，無法插在圖形之間）。存檔時保留檔案中的元素順序；縮圖、嵌入與 Mac 檢視依檔案順序繪製。
- **元素範圍**：可**顯示**所有標準類型（rectangle、diamond、ellipse、line、arrow、text、freedraw、image、frame，含 `angle` 旋轉、曲線與 elbow 箭頭）；可**建立**的是 rectangle、ellipse、arrow（直線，可綁定）、text、image、frame。`embeddable`、`iframe` 等顯示為帶標題的佔位框，原樣保留。不模擬 rough.js 的手繪風格：`roughness`、`fillStyle`、`fontFamily` 原樣保留，顯示時用乾淨線條與系統字型；新元素 `roughness: 0`。
- **元素順序與 fractional index**：新版 Excalidraw 的元素有 `index`（fractional index）。有 `index` 時依它排序，新元素產生合法的 index（插在兩者之間）；合併後依 `index` 排序，沒有 `index` 的舊檔案沿用陣列順序。2026-10-02（4a）：演算法照 rocicorp/fractional-indexing（Excalidraw 用的同一套，base62）。所有元素都有合法 index 才算「有 index 的場景」；舊檔案不補 index（補了每個元素都要遞增 version），新元素也不加。index 相同（兩台裝置在同一處插入）時以 id 排序，兩邊合併結果一致。
- **箭頭綁定**：箭頭的 `startBinding` / `endBinding`（`elementId`、`focus`、`gap`，新版另有 `fixedPoint`）與形狀的 `boundElements` 兩邊一起維護。形狀移動或縮放後重算綁定箭頭的端點；只修改需要變的欄位並遞增 `version`。以 excalidraw.com 匯出的檔案當 fixture。2026-10-02（4a）：端點 = 從相鄰點朝錨點（`fixedPoint` 在形狀上的位置，沒有時用中心）的射線，與「形狀輪廓向外擴 `gap`」的交點，所以端點到輪廓的距離就是 `gap`；形狀可旋轉，矩形、橢圓、菱形各自算輪廓。`focus` 只為舊版 Excalidraw 近似計算，以 `fixedPoint` 為準。elbow 箭頭的端點暫不重算（需要重新走線）。刪除形狀 → 箭頭的該端綁定清除；刪除箭頭 → 從形狀的 `boundElements` 移除；箭頭單獨移動而形狀沒動 → 解除該端綁定。
- **文字**：`containerId` 綁在形狀內的文字隨形狀移動、在形狀內置中換行。編輯時在元素上疊原生 `UITextView` / `NSTextView`（注音組字是原生的），結束編輯才寫回元素。
- **圖片**：標準格式 `files[fileId].dataURL`（base64 內嵌，excalidraw.com 才打得開）。插入時用 ImageIO 縮到最長邊 2048px 並轉 JPEG（有透明度的圖保留 PNG），避免 JSON 暴增；`fileId` 由內容 hash 決定，同一張圖只內嵌一次；刪除元素不刪 `files`（與 Excalidraw 相同）。顯示依尺寸產生縮圖，不解碼原圖。
- **frame**：子元素以 `frameId` 指向 frame；移動 frame 時子元素一起移動，frame 內容依 frame 範圍裁切。
- **修改即遞增 version**：任何元素改動都遞增 `version`、重抽 `versionNonce`、更新 `updated`，元素層級合併（`ExcalidrawScene.merge`）依賴它們。
- **手勢分工**：筆模式下 Pencil 書寫、手指捲動與縮放（iPad 固定 `drawingPolicy = .pencilOnly`，不跟隨系統「僅使用 Apple Pencil 繪圖」設定；iPhone 通常沒有 Pencil，手指也能書寫）；手指點一下選取（空白處取消），長按約 0.35 秒才拖曳圖形，避免捲動時誤抓。選取模式停用 PencilKit 的手勢，手指與 Pencil 碰到圖形就拖曳。
- **Undo**：結構操作註冊在 `PKCanvasView` 的 `undoManager`，與筆畫依時間順序共用一個堆疊（⌘Z、三指手勢都適用）。
- **開啟中的白板接收外部變動**：Whiteboard 註冊 `EditorController`：`externalChange` 把磁碟內容以 `ExcalidrawScene.merge` 併進記憶體中的場景並更新畫面；`flush` 立即存檔。否則開著白板時同步或 Claude Code 寫入的元素會被舊場景覆蓋。
- **連結**：元素的 `link` 若是 `[[筆記]]`，`index()` 收進 `links`（白板出現在反向連結）；`renameLinks` 更新 `link` 與 `customData.easynotes.file`。
- **渲染器共用**：`SceneRenderer`（CoreGraphics，可在背景執行緒）同時用於列表縮圖、`![[x.excalidraw]]` 嵌入與 Mac 檢視；編輯器的 layer 樹沿用同一套幾何（路徑、文字排版）。2026-10-02（4b）：幾何集中在 `ElementGeometry`（輪廓、線與曲線、箭頭頭部、旋轉、畫面範圍），`SceneRenderer` 與 layer 樹都從它取 `CGPath`；`SceneRenderer.draw(in:visible:)` 只畫與可見範圍相交的元素，Mac 檢視直接用它。

2026-10-02 決定（4c 開工前）：

- **工具列**：~~獨立的 SwiftUI 工具列放筆、橡皮擦、套索、選取與各種建立工具~~（2026-10-02 實機回報後改為 Freeform 式，見下方「工具列改版」）。
- **編輯核心不依賴平台**：工具狀態、選取、hit test、拖曳 / 縮放 / 建立的手勢狀態機都在畫布座標下運作，只呼叫 `ExcalidrawScene` 的編輯 API，可以用單元測試驗證；iOS（`PKCanvasView`）與 macOS（`NSView`）只負責把觸控 / 滑鼠事件換成畫布座標交給它。layer 樹（`CALayer`）兩個平台共用。
- **無限畫布**：Excalidraw 的座標可以是負數，`PKCanvasView` 的內容座標從 0 開始，所以 `內容座標 = 場景座標 − origin`。開啟時 origin 與 `contentSize` 取「內容範圍外擴一圈留白」；捲到接近邊緣時擴大，origin 變動時筆畫平移、`contentOffset` 跟著補償，畫面不跳動。存檔時把筆畫換回場景座標，檔案裡永遠是場景座標。
- **畫布固定淺色**：結構元素的顏色寫在檔案裡（`#1e1e1e` 等），PencilKit 在深色模式會自動反轉筆畫顏色，兩者會不一致，所以編輯器畫布固定淺色（`overrideUserInterfaceStyle = .light`、背景用 `viewBackgroundColor`）。深色模式（像 Excalidraw 那樣整張反相）之後再做。
- **Undo**：每個結構操作記下受影響元素修改前後的字典，註冊在 `PKCanvasView` 的 `undoManager`（與筆畫共用一個堆疊）。復原時寫回修改前的內容，但 `version` 一律繼續遞增（不回到舊版號），否則其他裝置會以為沒有變動、合併時丟掉復原。

2026-10-02 編輯核心的細節（4c）：

- **`BoardEditor`**（`KindWhiteboard/Editor/`，`@Observable`）：持有工具、選取與手勢狀態，直接修改 `BoardDocument` 的場景。事件介面只有畫布座標：`tap` / `begin` / `drag` / `end` / `cancel`（加上 Shift），宿主負責換算座標與決定哪些觸控交給它。操作中逐幀修改場景（`version` 跟著遞增，與 Excalidraw 相同），結束時才註冊一筆 Undo、排存檔。
- **存檔**：`BoardDocument.edit` 只改記憶體並標記待存；宿主停止操作 500 ms 後（或離開、外部變動前）`commit` 一次寫入，與筆畫共用同一個計時器。
- **hit test**：最上層優先；有填色的形狀、文字、圖片點內部即可，透明形狀與 frame 只點得到邊框（frame 另含標題），已選取的元素點內部也算；容差是螢幕上固定的點數（除以縮放倍率）。形狀內的文字選到容器；`groupIds` 選到最外層群組的所有元素；`locked` 與手寫不能選（iOS 手寫交給套索，Mac 手寫只能看）。
- **建立圖形**：矩形、橢圓、frame、箭頭都是拖曳建立，拖曳距離太短就不建立；建立後切回選取工具並選取新元素。箭頭起點、終點落在可綁定形狀上（含邊框外一點容差）就綁定；frame 建立時把完全在範圍內的元素收進去。
- **縮放**：單一元素在自身（未旋轉）座標系縮放、對角固定；多選依整體範圍等比例換算每個元素的矩形。每一幀都從開始拖曳時的原始元素計算，不累積誤差。不允許翻轉（最小 1）。單一箭頭顯示兩端控制點，拖曳端點可重新綁定或解除。
- **選取外框**：`SelectionOverlay`（CALayer，兩個平台共用）在 PencilKit 上方、以螢幕座標畫選取框、控制點、框選範圍與綁定目標的提示，所以控制點大小不隨縮放改變。
- **文字編輯**：編輯器只記錄「正在編輯哪段文字」（既有文字、形狀內的文字，或新文字的位置）與開始時的場景；宿主依它在元素上疊原生文字框（iOS `UITextView`、Mac `NSTextView`），字級、行高、顏色、對齊、旋轉與元素相同並跟著縮放，編輯中隱藏該元素的 layer。輸入過程只改文字框，不碰場景（注音組字中不打斷）；結束編輯（點畫布其他地方、換工具、Esc、離開白板）才一次寫回並註冊一筆 Undo。進入方式：文字工具點空白處 → 新文字（插入點在點下的位置垂直置中）；文字工具點文字或形狀、選取工具雙擊文字或形狀 → 編輯該文字 / 形狀內的文字（沒有就新增，`containerId` 綁定）；選取工具雙擊空白處 → 新文字。結束時內容空白：新文字不建立，既有文字刪除（形狀內的文字刪除後形狀保留）。之後切回選取工具並選取該文字（形狀內的文字選取容器）。新文字預設字級 20、`#1e1e1e`。
- **插入圖片**：工具列的「圖片」是選單（照片、檔案、貼上），不是常駐工具。解碼與縮圖（`ExcalidrawScene.downscale`）在背景執行，回主執行緒才插入；圖片中心放在畫面中央，顯示尺寸最長邊約螢幕上 400 點（除以縮放倍率）。插入後切回選取工具並選取圖片，一筆 Undo（`files` 不隨 Undo 移除，與刪除相同）。照片用 `PhotosPicker`（不需要相簿權限）。
- **iOS 工具與手勢**：~~`PKToolPicker` 只放墨水類，橡皮擦與套索在 SwiftUI 工具列~~（見下方「工具列改版」）。結構操作時停用 `drawingGestureRecognizer`，由編輯器的拖曳手勢接手（`canvas.panGestureRecognizer` 要等它失敗才捲動）：Pencil 碰哪都算（空白處框選），手指只有碰到元素或控制點才拖曳、空白處維持捲動。

2026-10-02 工具列改版（實機回報：工具列的筆 / 橡皮擦 / 套索與 PencilKit 工具盤重複；換工具後工具盤消失叫不回來；筆模式選形狀變成套索）。改成 Freeform 式：

- **上方工具列**：畫筆、便條紙、形狀、文字框、圖片；有選取時加上再製、刪除；最後是 Undo / Redo。獨立一排，放在導覽列（檔名、設定）下方、畫布上方（`safeAreaInset(edge: .top)`），iPad 與 iPhone 相同；不放進導覽列（2026-10-02 第二輪回饋：與檔名擠在同一列）。Mac 之後共用（沒有畫筆）。
- **畫筆 = 手寫模式開關**，不是工具：開啟時顯示 `PKToolPicker`（鋼筆、鉛筆、麥克筆、單線筆、橡皮擦、套索、尺；墨水只放這四種，其他墨水存成 freedraw 會失真），Pencil 交給 PencilKit，手指點一下選取、長按才拖曳、雙擊編輯文字。關閉時隱藏工具盤、停用 PencilKit 手勢，Pencil 與手指都是選取。開啟時一定讓 `PKCanvasView` 成為 first responder（文字編輯結束後也是），工具盤才叫得回來。手寫模式記在 `BoardEditor.inking`（平台無關）。
- **插入而不是拖曳建立**：形狀（彈出面板只顯示圖示：矩形、圓角矩形、橢圓、菱形、箭頭、Frame；名稱只給 VoiceOver）、便條紙、文字框都插在畫面中央、選取新元素、一筆 Undo。中央已有同位置的元素時往右下錯開 20，連按不會疊在一起。預設尺寸：形狀 160×160（螢幕點，除以縮放倍率，下同）、箭頭長 200、Frame 400×300（不收進既有元素）。`BoardTool` 的拖曳建立留在編輯核心，給 Mac 與鍵盤快捷鍵用。
- **選取方式：矩形 / 套索**（第三輪回饋）：工具列一個按鈕切換（圖示顯示目前的方式），存在 App 偏好設定（`@AppStorage("whiteboardSelectionShape")`）。只影響非手寫模式下 Pencil 在空白處拖曳的範圍選取；手寫模式的筆畫選取仍是 PencilKit 工具盤的套索。套索在編輯核心是 `.lasso` 手勢，記錄經過的點（相距至少 3 螢幕點），選取「取樣點全部落在套索多邊形內」的元素：形狀取輪廓路徑的節點、線與箭頭取各點、文字與圖片取四角，都套用旋轉；放開時多邊形自動閉合。`SelectionOverlay` 以虛線畫出套索。限制：手寫在 `PKCanvasView`、結構元素在自己的 layer，同一次選取無法同時選到兩者一起移動（要做就得自己實作筆畫的選取與移動，另議）。
- **選其他工具就離開手寫模式**（第四輪回饋）：按便條紙、形狀（選了形狀時）、文字框、圖片（選了來源時）或選取方式按鈕，都會先關閉手寫模式（工具盤隱藏、回到選取），由編輯核心的插入 API 自己設定 `inking = false`。Undo / Redo、再製、刪除不改模式。
- **便條紙**：標準元素組合，excalidraw.com 打得開：無外框的方角 rectangle（`backgroundColor: #ffec99`、`strokeColor: transparent`）200×200，插入後直接編輯其中的文字（`containerId`）。插入與文字各一筆 Undo；沒打字也保留便條紙（與 Freeform 相同）。
- **文字框**：在畫面中央開始一段新文字（不看中央有沒有元素）。
- **畫布背景**：右下角選單：無、網格、點狀。是 App 的偏好設定（`@AppStorage("whiteboardBackground")`，預設點狀），所有白板共用、不寫進檔案：Excalidraw 沒有點狀背景的欄位，自訂 `appState` 欄位會在 excalidraw.com 存檔時被丟掉，也是相容性風險。（曾考慮 Excalidraw 的 `appState.gridModeEnabled`，但它只有網格、還會開啟吸附，語意不同。）只在編輯器顯示，縮圖與嵌入不畫。畫法：兩層 `CAReplicatorLayer`（點或線）放在結構層底下、跟著同一個 transform；間距 20 的 2ⁿ 倍，讓螢幕上的間距至少約 14 點；點的大小與線寬每幀除以縮放倍率，螢幕上維持固定。

2026-10-02 決定（4c：macOS 宿主、快捷鍵、LOD）：

- **macOS 宿主**（`BoardMacCanvasView`，`NSView`）：Mac 沒有 `PKCanvasView`，所以不用 `NSScrollView`，自己管平移與縮放：`origin`（畫面左上角的場景座標）與 `zoom`（0.25…4），螢幕座標 = (場景座標 − origin) × zoom，結構層、背景、`SelectionOverlay` 與 iOS 共用同一套 layer 與 transform 規則。座標本來就以場景為準，所以不需要 `CanvasRegion`（無限畫布免費）。`BoardLayerTree(drawsFreedraw: true)`：手寫由結構層畫（不可選取、不可編輯，但搬動 frame 時會跟著走，存檔時原樣保留）。畫布固定淺色（`appearance = .aqua`），與 iOS 相同。
- **輸入**：雙指捲動 = 平移；⌘ / ⌥ + 捲動、觸控板捏合 = 以游標為中心縮放；滑鼠按下 / 拖曳 / 放開直接交給 `BoardEditor`（`begin` / `drag` / `end`）。沒有移動（< 3 點）的按下視為點選：取消這次操作、還原選取、改呼叫 `tap`（Shift 加減選才正確）；雙擊 = 編輯文字。文字框是 `NSTextView`（注音組字是系統的），用 `bounds` ≠ `frame` 縮放內容，編輯中縮放不改字型、不打斷組字；`cancelOperation` 結束編輯（組字中的 Esc 由輸入法處理）。Undo 用視圖自己的 `UndoManager`（結構操作的堆疊，Mac 沒有筆畫），經 Edit 選單與 ⌘Z 使用。
- **工具列**：沿用 iPad 那一排（`BoardToolbar`，兩個平台同一個 view），Mac 隱藏畫筆；用快捷鍵選了建立工具時，對應的按鈕反白。不放進視窗工具列，避免與 2.5b 的麵包屑、New Document 擠在一起。
- **鍵盤快捷鍵**（平台無關，`BoardShortcut`，Mac 與 iPad 外接鍵盤共用）：V 選取、R 矩形、O 橢圓、A 箭頭、T 文字、F frame（不帶修飾鍵）、Delete / ⌫ 刪除、⌘D 再製、⌘A 全選、⌘C / ⌘X / ⌘V 剪貼簿、Esc（結束文字編輯 → 回到選取工具 → 取消選取）。文字框、手寫模式中不攔截（letters 要打進文字框）。
- **拖曳到邊緣自動捲動**（Mac）：拖曳中（移動、縮放、框選 / 套索、拖曳建立、箭頭端點）游標進入畫面邊緣 32 點內或跑出畫面時，畫面往那個方向捲動，越靠近邊緣越快、最快 900 點 / 秒（`EdgeAutoscroll`，平台無關）。每一幀平移畫面後，把同一個游標位置換成新的畫布座標交給 `BoardEditor.drag`，所以框選範圍、移動中的元素都跟著延伸；放開、Esc 取消或游標回到中間就停。只在有捲動時開 display link。iPad 不做（手指拖曳時另一隻手可以捲動）。
- **游標**（Mac）：建立工具（矩形、橢圓、箭頭、frame）是十字、文字工具是 I 形、選取是箭頭；以 `resetCursorRects` 管理，工具改變時（快捷鍵、工具列、建立完回到選取）以 Observation 追蹤 `editor.tool` 立即更新。
- **拖放圖片**（Mac）：畫布接受 Finder 的圖片檔、檔案承諾（照片 App 等，先收到暫存資料夾再讀）、瀏覽器拖出的圖片資料（PNG / TIFF / JPEG / HEIC）。圖片中心放在放開的位置，多張依序往右下錯開 20 點，每張一筆 Undo；解碼、縮圖與插入走與工具列相同的 `BoardEditor.insertImage(_:center:)`。不接受 `.excalidraw` 等其他檔案（貼上 Excalidraw 元素仍用 ⌘V）。
- **LOD**（`BoardLOD`，兩個平台共用）：縮放倍率 ≤ 0.4 且可見範圍內的元素 > 1,500 個時，以 `SceneRenderer` 在背景把可見範圍（外加一半畫面的緩衝）畫成一張點陣圖，放在結構層位置，結構層改為不建立 layer（已建立的移除）；快照準備好之前仍顯示個別 layer，所以不會空白。縮放或平移時圖片跟著 transform（暫時模糊），停止操作 150 ms 後依新範圍與倍率重畫。倍率回到門檻以上就關閉 LOD、分批重建 layer。iOS 的快照不含手寫（`PKCanvasView` 自己畫）。
2026-10-02 決定（4c：樣式面板）：

- **入口**：有選取時工具列多一個「樣式」按鈕（再製、刪除旁），彈出 `StylePanel`（SwiftUI，iPad 與 Mac 同一個 view）。面板只顯示選取元素適用的區塊，多選時值不一致就不標記任何選項（滑桿顯示「混合」）。
- **欄位全部是 Excalidraw 標準欄位**，不加自訂欄位，excalidraw.com 打得開也改得動：
  - 填色 `backgroundColor`：矩形、菱形、橢圓。
  - 外框 `strokeColor` / `strokeWidth`（細 1、中 2、粗 4）/ `strokeStyle`（實線、虛線、點線）：矩形、菱形、橢圓、線、箭頭。外框顏色多一個「無」（`transparent`，便條紙就是這樣）只給形狀。
  - 圓角 `roundness`：矩形（`{type: 3}`）、菱形（`{type: 2}`）；直角 = `null`。
  - 箭頭 `startArrowhead` / `endArrowhead`：無、箭頭、三角形、橫線、圓點、菱形。
  - 文字 `strokeColor`（字色）/ `fontSize`（小 16、中 20、大 28、特大 36，與 Excalidraw 相同）/ `textAlign`（左、中、右）：文字，以及選到的形狀內的文字。改字級後重新排版：獨立文字依 `textAlign` 固定左緣 / 中心 / 右緣、上緣不動；形狀內的文字依容器排版，文字變高時容器長高。
  - 透明度 `opacity`（0–100，間隔 10）：frame 以外的元素；形狀的透明度也套用到它的文字。
- **只用預設色盤，不做自訂顏色**：照 Excalidraw 調色盤，外框 / 字色用第 4 階（深）、填色用第 1 階（淺）。外框：`#1e1e1e`、`#868e96`、`#e03131`、`#c2255c`、`#9c36b5`、`#6741d9`、`#1971c2`、`#0c8599`、`#099268`、`#2f9e44`、`#f08c00`（形狀多一個「無」，一排 6 個剛好兩排）。填色：無、`#e9ecef`、`#ffc9c9`、`#fcc2d7`、`#eebefa`、`#d0bfff`、`#a5d8ff`、`#99e9f2`、`#96f2d7`、`#b2f2bb`、`#ffec99`、`#ffd8a8`。檔案裡其他顏色照常顯示，只是面板不標記。
- **編輯 API**：`ExcalidrawScene.setStyle(_ ids:, _ change: StyleChange)`（模型層，只改適用的元素、內容有變才遞增 version，可單元測試）；`BoardEditor.setStyle` 每次點選一筆 Undo。透明度滑桿拖曳中逐幀修改、放開才註冊一筆 Undo。
- **新元素沿用上次的樣式**（Excalidraw 的 `currentItem*`）：面板改過的值記在 `BoardEditor.currentStyle`（只在記憶體，關閉白板就回到預設），之後插入或拖曳建立的形狀、箭頭、文字套用適用的部分。便條紙、frame、圖片不套用。

2026-10-02 決定（4c：箭頭連接點吸附）：

- **連接點**：可綁定的形狀（矩形、菱形、橢圓、文字、圖片）各有 4 個連接點：上、右、下、左邊的中點（`fixedPoint` 為 `[0.5, 0]`、`[1, 0.5]`、`[0.5, 1]`、`[0, 0.5]`，跟著 `angle` 旋轉；橢圓、菱形剛好是四個頂點）。
- **吸附**：拖曳建立箭頭或拖曳箭頭端點時，端點距離某個連接點小於 14 螢幕點（除以縮放倍率）就吸過去：拖曳中端點直接顯示在吸附位置，放開時綁定並寫入該 `fixedPoint`。沒有靠近連接點、但落在形狀上時維持原本的行為（`fixedPoint` = 放開位置投影到形狀上的比例）。範圍可以略超出形狀邊框（連接點在邊上）。
- **端點位置**：`fixedPoint` 是四邊中點時，端點 = 該中點沿那一邊的外法線方向外移 `gap`（不走射線），箭頭從形狀背後過來時也停在指定的那一邊；其他 `fixedPoint` 照舊用射線與「輪廓外擴 gap」的交點。形狀移動、縮放、旋轉後依同一規則重算。
- **提示**：`SelectionOverlay` 在綁定目標上畫出 4 個連接點（白底），吸附中的那個實心放大。
- **不做**：轉折線（elbow）與曲線箭頭的走線，新箭頭仍是兩點直線。

#### 筆記卡片放進白板（Heptabase / Obsidian Canvas 式，選做）

難度中等，前提是白板結構層已完成。

- **格式**：用一個 rectangle 元素代表卡片，`link` 設為 `[[筆記]]`，`customData.easynotes.file` 記錄檔案路徑（改名時由連結改名流程一併更新）。在 excalidraw.com 上會優雅降級成一個帶連結的框。
- **顯示**：白板向 Registry 要 `.md` 的 DocumentPreviewProvider，由 Markdown 外掛產生唯讀預覽（標題 + 前幾段），外掛之間仍不互相依賴。
- **互動**：點卡片在側邊面板開啟完整編輯器。不做畫布內直接編輯：縮放中的畫布上要同時跑多個 CM6 編輯器，成本高、收益小。
- **互通**：需要與 Obsidian Canvas 互通時，另做 JSON Canvas（`.canvas`）匯出即可，不必多維護一種畫布格式。

### PDF 手寫與標註

- **做**：開啟 PDF；原子筆、螢光筆、橡皮擦、套索選取、便利貼；匯出合併標註後的 PDF。
- **不做**：插入空白頁、頁面縮圖與重排、PDF 文字搜尋、手寫辨識、建立新 PDF（只能匯入）。
- **實作**：`PDFView` + `PDFPageOverlayViewProvider`，每個可見頁面疊一個 `PKCanvasView`，離開畫面就回收，避免大檔案吃光記憶體。`drawingPolicy = .pencilOnly`，手指捲動與縮放、Pencil 書寫。
- **格式**：原始 PDF 不改動。標註存在 `<檔名>.pdf.ink`（JSON）：`pdfHash` + 依頁碼分組的 Excalidraw elements。檔案樹中隱藏 `.pdf.ink`。
- **平台**：macOS 顯示 PDF 與所有標註，便利貼可新增、移動、編輯；手寫只能看。

2026-10-02 決定（Phase 5 開工前）：

- **共用 `ExcalidrawKit`**：元素模型、`merge`、`InkStroke` / PencilKit 轉換、`ElementGeometry`、`TextLayout`、`ElementPainter`、`SceneRenderer` 從 KindWhiteboard 搬進共用函式庫（見「依賴規則」），兩個外掛都依賴它。layer 樹、編輯核心、文字框等畫布元件留在 KindWhiteboard；PDF 真的需要時再個別搬。
- **旁檔格式**：

  ```json
  {
    "type": "easynotes-pdf-ink",
    "version": 1,
    "pdfHash": "<PDF 的 SHA-256>",
    "pages": { "0": { "elements": [ /* Excalidraw elements */ ] } },
    "files": {}
  }
  ```

  頁碼從 0 開始，沒有標註的頁不寫。座標是該頁 cropBox 的**未旋轉**頁面座標：單位 PDF point、原點左上、y 向下（與 Excalidraw 相同）；顯示與匯出時才套用頁面的 `rotation`。元素沿用 Excalidraw 規則（`version`、`versionNonce`、`updated`），未知欄位原樣保留。
- **筆畫**：原子筆 = `com.apple.ink.pen`、螢光筆 = `com.apple.ink.marker`（freedraw 的 `opacity` 保留透明度），都經 `ExcalidrawKit` 的 `InkStroke` 轉換；橡皮擦、套索是 `PKToolPicker` 的系統工具。
- **便利貼**：與白板的便條紙相同的標準組合（無外框 rectangle `#ffec99` + `containerId` 文字），直接顯示在頁面上、可移動與縮放，預設 160×160 頁面點、字級 14。編輯時疊原生文字框（iOS `UITextView`、Mac `NSTextView`），注音組字中不寫回。疊放順序：頁面 < 便利貼 < 手寫（與白板「手寫在結構元素之上」一致，可以在便利貼上寫字）。
- **頁面疊層**：overlay view = 便利貼 layer（`ElementPainter`）+ `PKCanvasView`。手寫模式開關與白板相同（畫筆 = 開關，開啟時顯示 `PKToolPicker`：鋼筆、螢光筆、橡皮擦、套索）；手寫模式中手指捲動縮放、長按便利貼才拖曳；關閉時 Pencil 與手指都能點選、拖曳便利貼。iPad `.pencilOnly`，iPhone 只在手寫模式用手指書寫。所有頁面共用一個 `PKToolPicker`。
- **記憶體**：記憶體中的標註是「頁碼 → elements 字典」（便宜）；`PKDrawing` 只為有 overlay 的頁面建立，overlay 回收時把筆畫換回 elements。
- **Undo 記在模型，不靠 `PKCanvasView`**：overlay 會被回收，PencilKit 註冊在畫布上的 undo 會指向已釋放的 view。`PKCanvasView` 子類別回傳私有的 `undoManager`（吞掉 PencilKit 自己的註冊），`canvasViewDrawingDidChange` 時比對前後筆畫，以「頁碼 + 前後 elements」註冊到視窗的 undoManager；復原時改模型，頁面在畫面上才同步給畫布。跨頁依時間順序復原；`version` 一律遞增（同白板）。S4 驗證可行性。
- **存檔與外部變動**：停止操作 500 ms 後寫入旁檔；註冊 `EditorController`，`externalChange`（同步拉下來的旁檔）以元素合併併進記憶體並更新可見頁面，`flush` 立即存檔。
- **合併**：`.pdf` 是不透明檔案（內容不同 → 衝突副本）。`.pdf.ink` 依頁合併，每頁用白板的元素合併（`id` + `version`）；`pdfHash` 不同時保留本機的。
- **PDF 被換掉**（`pdfHash` 不符）：仍依頁碼顯示標註，頂端提示「PDF 已變更，標註可能錯位」，按「保留標註」才更新 `pdfHash`。
- **伴隨檔案（Core 擴充點，不認識類型）**：`DocumentKind.companionOf`（預設 nil），`.pdf.ink` 回傳「去掉 `.ink` 的路徑」。Core 據此：檔案樹、文件列表、搜尋不顯示伴隨檔；App 內改名、搬移、刪除、還原主檔時伴隨檔一起處理；仍照常索引 hash、同步與合併。外部工具改名 PDF 時，VaultWatcher 推斷出主檔改名就一併搬移旁檔；推斷不到時，開啟沒有旁檔的 PDF 會以 `pdfHash` 找主檔不存在的孤兒旁檔認領。
- **索引與預覽**：`PDFKind.index` 只有標題與摘要（「N 頁」）；便利貼文字暫不索引。列表縮圖 = 第 1 頁（不含標註，依 PDF hash 快取；旁檔變動不會讓縮圖失效）。
- **匯入**：`addImport("匯入 PDF…")` 複製到目前資料夾；Vault 裡既有的 PDF（例如 `附件/`）因為註冊了 `.pdf` 也會出現在列表。
- **匯出：全部壓平**：用 `CGPDFContext` 逐頁畫原頁面（`PDFPage.draw(with: .cropBox, to:)`），再套用頁面旋轉、以 `SceneRenderer` 用向量畫上筆畫與便利貼；螢光筆的透明度由 CG alpha 保留。產出新檔（分享，或存成 Vault 內的 `<檔名>（標註）.pdf`），原始 PDF 不動。匯出後在其他 App 不能再編輯標註，換來任何閱讀器與列印都一致。

### Sheets（`.csv`、`.tsv`）

- **做**：RevoGrid 編輯（修改儲存格、增刪列欄、排序與篩選檢視）；欄寬、凍結欄等顯示設定存 `.csv.meta.json`；在 md 內 `![[x.csv]]` 嵌入表格預覽。
- **不做**：公式、多工作表、圖表。CSV 只存資料；需要試算表功能時用「用其他 App 開啟」交給 Numbers / OnlyOffice。
- **實作**：Swift 端做 RFC 4180 解析與序列化，WebView 只拿列資料。未修改的列逐位元組寫回（引號風格、換行符不變），讓 diff 與合併保持乾淨。

2026-10-02 決定（Phase 6 規劃；依 Roadmap 順序，Phase 5 完成後才開工）：

- **外掛**：新增 `Packages/KindSheet`，只依賴 EasyNotesCore / EasyNotesUI。`.csv` 與 `.tsv` 都支援，同一套解析器，只差分隔符（`,` / tab）。
- **先驗證注音（S5 Spike）**：最大的風險是 RevoGrid 在 WKWebView 中的注音輸入。試算表習慣「選取儲存格後直接打字就進入編輯」，第一個按鍵在組字中，容易吃字或重複；做法是在選取的儲存格位置放一個常駐焦點的隱藏 `textarea`（同 Google Sheets），組字中的 Enter（`isComposing`）不結束編輯。Spike 同時量 1 萬列捲動、bundle 大小與關閉後 WebContent process 是否釋放。不通過就改用自寫的 TS 虛擬表格或原生 `UICollectionView` / `NSTableView`；6a 的模型不受影響。
- **模型：保留原始位元組**：每筆記錄（record）保留原始位元組與解析後的欄位；未修改的記錄原樣寫回，修改過的記錄依檔案的風格重新產生。偵測：換行符（LF / CRLF，取多數）、引號風格（全部加 / 必要時才加）、BOM、檔尾是否有換行。欄數不一的列原樣保留，顯示時補空格，未編輯就不寫回補的空格。
- **編碼**：UTF-8（含或不含 BOM）可編輯；偵測為 Big5（台灣 Excel 匯出常見）時唯讀開啟，提供「轉成 UTF-8」。
- **索引**：標題 = 檔名；`plainText` = 儲存格內容（設上限，避免巨大檔案拖慢 FTS）；摘要「CSV · 86 列 · 5 欄」；儲存格中的 `[[連結]]` 收進 `links`，`renameLinks` 一併更新。
- **合併**：以**記錄**為單位的 diff3（帶引號的欄位可以跨行，所以不是以實體行為單位），直接用 Core 的泛型 `Diff3.merge`。兩邊改了同一筆記錄的不同儲存格時，再以儲存格為單位做三方合併；新增或刪除欄會讓每一列都變動 → 衝突副本（接受）。
- **編輯器與 Bridge**：每次開檔建立自己的 `WebEditorHost`、關閉後釋放（不與 Markdown 的預熱 WebView 共用）。`load({rows, meta})` 一次送出全部列，每列帶 Swift 給的穩定 row id（排序或篩選後仍能對回原本的列）；JS 在**儲存格編輯結束時**才送 `edit({ops})`（`setCell`、增刪列欄），不是每個按鍵，打字熱路徑不跨 Bridge。Swift 把 ops 套到模型上，延遲 300 ms 寫檔。註冊 `EditorController`：`externalChange` 重新解析後以 `applyRemote` 更新並盡量保留選取，`flush` 立即存檔。Undo 由 JS 以 op 堆疊實作。剪貼簿用 TSV，與 Numbers / Excel 互通。`addMenu("表格")` 提供插入 / 刪除列欄、凍結首欄。
- **排序與篩選只影響畫面**：不改寫檔案（整檔重新排序會讓每一列都變動，diff3 無法合併）；需要時提供明確的「依此欄排序並寫入」。
- **顯示設定 `.csv.meta.json`**（`.tsv.meta.json` 相同）：`{version, columns: [{width}], frozenColumns, headerRow}`；只在使用者改了顯示設定時才建立；增刪欄時由編輯器一起調整。以 Phase 5 的 `companionOf` 註冊為伴隨檔（列表隱藏、跟著主檔改名搬移刪除）；合併以欄位為單位 LWW。
- **預覽與嵌入**：`makePreview` 在背景用 CoreGraphics 畫前約 8 列 × 6 欄的 PNG（設計稿 Thumb CSV `otUrV`），`![[x.csv]]` 經 `embed://` 用同一張圖；深色模式同白板（透明背景、顯示端反相）。
- **新增與匯入**：`addKind`（`tablecells`、`type-csv`）、`addNewFile("新表格")`（範本只有一列標題）、`addImport("匯入 CSV…")`；`addVaultGuide` 說明 CSV 慣例（UTF-8、第一列是標題、不要手動修改 `.csv.meta.json`）。

### Flashcards

2026-10-02 決定（Phase 3 開工前）：排程用 swift-fsrs 的 FSRS-6、參數優化用 fsrs-rs；資料夾 = 牌組、標籤 = 篩選；設定以 preset 管理，預設值與 Anki 相同。

#### 卡片類型與身分

語法（類 RemNote）屬於 Vault 的 Markdown 方言：一行是一筆 note，行尾 `^id` 是 note 的身分，缺少時由 App 補上。一筆 note 依語法產生一或多張卡片，卡片 id = note id + 後綴：

| 語法 | 產生 | 卡片 id |
| --- | --- | --- |
| `光合作用發生在 :: 葉綠體 ^c-a1b2c3` | 1 張（正向） | `c-a1b2c3` |
| `中文 ;; Chinese ^c-d4e5f6` | 2 張（正向、反向） | `c-d4e5f6`、`c-d4e5f6:r` |
| `{{粒線體}}是{{細胞的發電廠}} ^c-g7h8i9` | 每個 `{{}}` 一張 | `c-g7h8i9:1`、`c-g7h8i9:2` |

- 同一行產生的卡片互為 sibling（「埋藏 sibling」的對象）。
- 卡片身分只跟 `^id` 綁定，與檔案路徑無關：整行剪下貼到別篇筆記，複習歷史跟著走。
- 複製貼上造成 `^id` 重複時，後出現的那一行重新產生 id。
- 刪掉這一行卡片就消失，紀錄留在 jsonl；同一個 `^id` 回來時歷史一併恢復。
- `::`、`;;` 前後要有空白（避免 `std::vector` 之類的文字被當成卡片）；程式碼區塊、行內程式碼與 frontmatter 內不解析卡片。
- `^id` 格式為 `c-` + 6 碼小寫英數，由「檔案路徑 + 該行內容」的 hash 決定：兩台裝置替同一行補 id 會得到相同結果，diff3 視為相同的修改，不會產生衝突。行尾已有其他 block id（例如 Obsidian 的 `^abc`）時直接沿用。
- 補 id 由 `ContentFixer` 執行（見「擴充點」）：開啟中的檔案不補，離開後才補。重複的 id：同一檔案內改後出現的那一行；與其他檔案重複時改目前處理的這個檔案（複製貼上的新位置）。
- 卡片類型是 Flashcards 外掛內部的 enum，Core 不認識。語法規格寫在 Vault 的 `CLAUDE.md`，Markdown 外掛（語法標示）與 Flashcards 外掛（解析）各自依規格實作，不互相 import。

#### 牌組

- **資料夾 = 牌組**：每篇筆記只在一個資料夾，所以每張卡片只屬於一個牌組。牌組有階層（同 Anki 的 `A::B`），母牌組的上限涵蓋所有子牌組；Vault 根目錄的筆記屬於根牌組。
- **標籤 = 篩選學習**（同 Anki 的 filtered deck）：可以臨時只複習「#考試」，但標籤沒有自己的上限與設定，也不改變卡片所屬的牌組。
- **Preset**：多個牌組共用一組設定（presets + 「資料夾路徑 → preset」），跟著同步，以欄位為單位 LWW 合併（檔案格式見「設定」）。沒有指定的資料夾繼承上層，根目錄用預設 preset。資料夾改名時與連結改名一樣一併更新路徑。

#### 排程

- **不自寫演算法**。排程用 swift-fsrs，參數優化用 fsrs-rs（Anki 本身使用的函式庫），透過 UniFFI 包成 Swift；兩者共用同一組 FSRS-6 的 21 個參數 `w`。
- **swift-fsrs 以 `revision:` 固定 commit**：FSRS-6 在 2026-05 合併進 `main`，但最後一個 release 仍是 v5.0.0（2024-10），且預設是 FSRS-5 的 19 個參數；初始化時明確傳入 `FSRSDefaults.defaultWv6` 或優化後的 `w`。
- **以參考向量做回歸測試**：與 fsrs-rs / py-fsrs 的結果比對；對不上且修不了時，排程也改用 fsrs-rs。
- **參數優化**手動執行（或累積一定筆數後提醒），紀錄太少時不允許；結果寫回 preset 的 `w`。

#### 複習紀錄與重播

- **紀錄**：`.easynotes/srs/<deviceId>.jsonl`，只由該裝置追加。欄位對齊 Anki 的 `revlog`（`id` 毫秒時間戳、`cid`、`ease`、`ivl`、`lastIvl`、`time`、`type`）。
- **卡片狀態不另存**：由重播所有裝置的紀錄算出，結果快取在可重建的索引中。
- **重播不重算間隔**：到期日一律採用紀錄中的 `ivl`（fuzz 有亂數，參數也可能被優化改掉）；只有記憶狀態（stability、difficulty）用目前的參數重算，與 Anki 換參數後的行為相同。這樣同一組紀錄在任何裝置都得到相同狀態。
- **手動操作也是事件**：暫停 / 恢復、重設、Leech 處理寫成 jsonl 事件（Anki revlog 的 Manual 類型），不寫進 md。

2026-10-02 決定（3b）：

- **紀錄格式**：一行一筆 JSON，欄位名稱與意義照 Anki `revlog`，另加 `op` 擴充欄位：

  ```json
  {"id":1759400000123,"cid":"c-a1b2c3:r","ease":3,"ivl":-600,"lastIvl":-60,"time":5320,"type":0}
  {"id":1759400100000,"cid":"c-a1b2c3:r","ease":0,"ivl":0,"lastIvl":0,"time":0,"type":4,"op":"suspend"}
  ```

  | 欄位 | 意義 |
  | --- | --- |
  | `id` | 複習時間（Unix 毫秒） |
  | `cid` | 卡片 id（`^id` + 後綴） |
  | `ease` | 1 Again、2 Hard、3 Good、4 Easy；手動事件為 0 |
  | `ivl` / `lastIvl` | 這次 / 上次的間隔；正數 = 天，負數 = 秒（learning steps） |
  | `time` | 作答花費的毫秒 |
  | `type` | 複習當下的狀態：0 Learning（含 New）、1 Review、2 Relearning、4 Manual |
  | `op` | 只在 `type: 4`：`suspend`、`unsuspend`、`reset` |

  讀取時容忍損壞的行（略過）、未知的 `op`（略過）與未知欄位；同一筆（`id` + `cid` + `ease` + `op`）出現在多個檔案（例如衝突副本）只算一次。
- **換日時間**：以 Anki 的方式計算「天」：當地時間的換日時間（預設凌晨 4 點）之後才算新的一天。swift-fsrs 以 UTC 午夜換日，所以包裝層把時間平移「時區偏移 − 換日時間」再交給它，結果再平移回來，不修改套件。
- **重播規則**：所有裝置的紀錄依 `(id, deviceId)` 排序後逐筆套用。評分事件用 swift-fsrs 以目前參數算出新的 stability / difficulty；複習後的狀態由 `ivl` 決定（負數 → Learning 或 Relearning，正數 → Review）；到期日 = `ivl` 天後的換日時間，或 `-ivl` 秒後。`reset` 回到 New，`suspend` / `unsuspend` 只切換暫停旗標。
- **作答與重播走同一條路徑**：作答時用 swift-fsrs（fuzz 開啟）算出 `ivl` 寫成紀錄，再用重播的同一個函式套用到卡片，所以即時狀態與重播結果不會不一致。
- **快取**：重播結果放在記憶體，App 啟動時在背景重播一次；本機作答只套用新的一筆，其他裝置的紀錄檔變動時只重播有新紀錄的卡片。2026-10-02 量測（M 系列 Mac、release）：10 萬筆紀錄約 1.3 秒，個人量級（數萬筆）在 0.5 秒內，所以先不寫到磁碟；之後若 iPhone 上太慢，再存到 `.easynotes/cache/srs/`（可刪除重建）或改成平行重播。
- **重播的效能**：swift-fsrs 對複習卡會一次算出四個按鈕，且每個數值都用 `String(format:)` 四捨五入，一筆約 47µs。記憶狀態只看 S、D、經過天數與評分，與卡片狀態無關，所以重播時一律以 learning 狀態交給 swift-fsrs，只算選到的那個評分（約 13µs），結果相同（參考向量測試涵蓋）。
- **learning steps 由包裝層處理**：swift-fsrs（同 ts-fsrs）在第二步以後按 Hard 會取前兩步的平均，Anki 與 py-fsrs 是重複目前這一步。所以交給 swift-fsrs 的 steps 留空，只用它算記憶狀態與以天計的間隔，steps 依 Anki 的規則自己處理。複習卡的 Hard ≤ Good < Easy 限制照 swift-fsrs（與 Anki 相同，py-fsrs 沒有）。

#### 設定

Preset（每個牌組，預設值與 Anki 相同）：

| 設定 | 預設 |
| --- | --- |
| 每日新卡上限 | 20 |
| 每日複習上限 | 200 |
| Learning steps | 1m 10m |
| Relearning steps | 10m |
| Desired retention | 0.90 |
| 最大間隔 | 36500 天 |
| FSRS 參數 `w`（21 個） | FSRS-6 預設；可執行優化 |
| Leech 門檻 / 動作 | 8 次 / 只加標籤（可改為暫停） |
| 新卡順序 | 依檔案內順序 / 隨機 |
| 複習排序 | 依到期日 / 依可回想率 |
| 埋藏 sibling | 新卡、複習卡各一個開關 |

全域：新的一天開始時間（預設凌晨 4 點）、按鈕上顯示下次間隔、參數優化提醒。

刻意不開放：起始 ease、Hard / Easy 倍率、interval modifier（SM-2 專用，FSRS 不使用）。fuzz 固定開啟（Anki 也不能關）。

2026-10-02 決定（3c）：

- **設定檔每台裝置各寫一個**：`.easynotes/srs/<deviceId>.config.json`，內容是這台裝置改過的欄位與修改時間。單一 `config.json` 沒有註冊的 `DocumentKind`，兩台裝置都改時會變成衝突副本；改成和複習紀錄一樣各寫各的，就不需要在 Core 加合併的擴充點。讀取時合併所有裝置的檔案，每個欄位取修改時間最新的值（相同時間比 deviceId），等同欄位 LWW。

  ```json
  {"version":1,"fields":[
    {"k":["presets","p-k3x9a2","name"],"v":"語言","t":1759400000123},
    {"k":["presets","p-k3x9a2","newPerDay"],"v":30,"t":1759400000123},
    {"k":["decks","日文"],"v":"p-k3x9a2","t":1759400000123},
    {"k":["global","rolloverHour"],"v":4,"t":1759400000123}
  ]}
  ```

  | 欄位 key | 值 |
  | --- | --- |
  | `presets/<id>/<欄位>` | preset 的欄位（`name`、`newPerDay`、`reviewsPerDay`、`learningSteps`…）；`deleted: true` = 已刪除 |
  | `decks/<資料夾路徑>` | preset id；`null` = 繼承上層 |
  | `global/<欄位>` | `rolloverHour`、`showIntervals`、`optimizeReminder` |

  key 用陣列，因為資料夾路徑含 `/`。內建的「預設」preset id 為 `default`，不能刪除；新增的 preset id 為 `p-` + 6 碼亂數。沒有出現的欄位用 Anki 的預設值。
- **資料夾改名**：App 內改名或搬移時（`moved`），把舊路徑與其下所有子路徑的 `decks/…` 寫成 `null`、新路徑寫入原本的 preset。Finder、Claude Code 的改名偵測不到，該資料夾回到繼承上層（不會遺失其他設定）。
- 刪除 preset：使用它的牌組改回繼承上層。

#### 每日上限與佇列（3c）

2026-10-02 決定，規則照 Anki 的 v3 排程器：

- **每日上限**：今天剩下的新卡數 = 上限 − 今天已學的新卡數（卡片的第一筆評分紀錄在今天）；複習數同理（今天 `type` 為 Review 的評分紀錄）。紀錄依卡片**目前**所在的牌組計算。從某個牌組開始複習時，套用這個牌組與其下各層子牌組的上限（上層牌組的上限不套用，與 Anki 相同）：卡片要同時通過從所選牌組到卡片所在牌組路徑上每一層的剩餘數。牌組列表的數字就是「從這個牌組開始」會拿到的張數，所以母牌組的數字會小於子牌組的總和。
- **新卡也受複習上限限制**（Anki 23.10 起的預設）：新卡數 ≤ 複習上限扣掉今天已複習與待複習的張數。
- Learning / Relearning 的卡片不受上限限制。
- **埋藏 sibling 不另存**：同一行今天已經複習過任何一張的卡片，當天不出現（新卡與複習卡各依設定）；佇列中同一行只放一張。由今天的紀錄推得，換日後自動解除，所以不需要 bury 事件。
- **新卡順序**：依檔案內順序 = 依路徑、行號、卡片 id 後綴；隨機 = 以「卡片 id + 日期」的 hash 排序（同一天內穩定）。**複習排序**：依到期日（早的在前）/ 依可回想率（低的在前）。
- **出卡順序**：已到期的 learning 卡最優先；其次把新卡平均穿插在複習卡之間；都沒有時，20 分鐘內到期的 learning 卡提前出現（Anki 的 learn ahead limit）。
- **Leech**：複習卡按 Again 使 lapses 達到門檻時（之後每多門檻的一半次再觸發一次）。動作「只加標籤」不改 md：`leech` 是由 lapses 算出的虛擬標籤，可以在標籤篩選中選它；動作「暫停」另外寫入 `suspend` 事件。
- **標籤篩選**（Anki 的 filtered deck）：選一個標籤，只複習所在筆記帶有該標籤的卡片，跨所有牌組、不受每日上限限制；先出已到期的，再出新卡，一次最多 100 張。
- **復原（U）**：從本機紀錄檔刪掉最後一行，再重播那張卡片。只能復原這次複習中、這台裝置寫入的紀錄，而且最後一行必須是它（中途被其他程式追加就不能復原）。紀錄檔只有本機會寫，所以刪掉最後一行同步出去也不會衝突。
- **到期數 badge**：側邊欄「複習」的數字 = 根牌組（含所有子牌組）的待複習 + learning 張數，已套用上限。

#### 複習介面（3c）

- 牌組列表（設計稿 `rHTaT`）：資料夾樹，只列出含有卡片的資料夾與其上層；Vault 根目錄的卡片顯示為「未分類」（放在最後）。可展開 / 收合，狀態存在本機。統計區塊（連續天數、retention、到期預測、熱力圖）不在 3c 範圍。
- 複習畫面（`b2AjRQ`）：顯示正面 → 顯示答案（Space）→ 四鍵（1–4，Space = Good）。卡片顯示來源檔案與行號、所在筆記的標籤、lapses。「編輯筆記」（E）以 `session.open(path, line:)` 開啟筆記；Esc 離開。克漏字：正面把目前這個 `{{}}` 換成 `[…]`、其他 `{{}}` 顯示內容；背面標示答案。
- 牌組選項（`AYlad`）：Sheet；preset 選單、preset 欄位、全域設定。「最佳化…」在 3d 前停用。

#### 互通

匯出 TSV 給 Anki 匯入；匯入 Anki `.apkg`（SQLite）與複習歷史為選做。

### 跨外掛功能

- `[[筆記]]` 連結；`![[圖.excalidraw]]`、`![[表.csv]]` 在 md 內嵌入預覽，預覽由各外掛向 Registry 註冊的 DocumentPreviewProvider 提供。
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
- `.easynotes/device-id`（不同步）：這台裝置的 id（`VaultFS.deviceID()`），`commit_file` 的 `device_id` 與複習紀錄的檔名都用它。
- `.easynotes/` 只有外掛以 `addSyncedMetaFolder` 註冊的子資料夾參與同步（目前是 Flashcards 的 `srs/`），其餘（`cache/`、`sync.sqlite`、`device-id`）都是本機的。
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
| `.excalidraw` | 依元素 `id` + `version` 合併（與 Excalidraw 官方協作相同） |
| `.pdf.ink` | 依頁分組，每頁依元素 `id` + `version` 合併；`pdfHash` 保留本機 |
| `.csv`、`.tsv` | diff3，以記錄為單位；同一記錄的不同儲存格再三方合併；增刪欄 → 衝突副本 |
| `.csv.meta.json` | 以欄位為單位 LWW |
| `.easynotes/srs/*.jsonl` | 每台裝置只寫自己的檔案，天然無衝突 |
| `.easynotes/srs/*.config.json` | 每台裝置只寫自己的檔案；讀取時以欄位為單位 LWW 合成 |
| 其他（`.pdf`、圖片） | 內容不同 → 衝突副本 |

## Claude Code 整合

- **Vault 根目錄的 `CLAUDE.md`**：說明 frontmatter 規範、卡片語法、資料夾慣例，以及不要手動修改的檔案（`.easynotes/srs/*.jsonl`、`.easynotes/srs/*.config.json`、`.easynotes/cache/`、`sync.sqlite`）。
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
- **嵌入預覽與筆記卡片**：原生渲染（白板用 CoreGraphics 的 `SceneRenderer`），結果以 PNG 存在預覽快取（依內容 hash），WebView 經 `embed://` 讀取。
- **白板**：只為畫面內的元素建立 layer；圖片依顯示尺寸產生縮圖。

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