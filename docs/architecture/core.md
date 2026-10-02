# Core：擴充點、同步與整合

## 擴充點

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
    func importAttachment(_ url: URL) async -> String?  // 複製到 Vault 的 `Attachments/`，回傳 Vault 內路徑
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
registry.addCompanionKind(PDFInkKind.self)                    // 伴隨檔類型：進 KindRegistry 照常索引、同步，但不是篩選 chip
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

**Flashcards 如何使用擴充點（3c）**：

- 不新增「服務」型的擴充點：Flashcards 註冊一個 `EditorController`（`ReviewStore`），在 `attach` 取得 session，靠 `vaultChanged` / `moved` 得知變動。`EditorController` 的意義從「編輯器」放寬為「App → 外掛的通知」。
- `vaultChanged(paths)` 只帶路徑，外掛自己決定要不要重讀（Flashcards：md 變動 → 重讀卡片 records；`.easynotes/srs/` 變動 → 重讀紀錄，只重播有新紀錄的卡片）。
- `open(path, line:)` 由 App 導覽到檔案後呼叫各 controller 的 `reveal`；不是打字熱路徑，可以跨 Bridge。
- `VaultIndex.fileTags()`：路徑 → 標籤（卡片的標籤 = 所在筆記的標籤）。

**同步外掛資料（3b）**：

- `addSyncedMetaFolder`：`.easynotes/` 預設不同步（索引、快取、同步狀態都是本機的）。外掛需要同步自己的資料時，註冊 `.easynotes/` 下的子資料夾，App 把清單交給 `SyncEngine`。用白名單而不是「`.easynotes/` 除了 cache 都同步」，避免 `seeded` 之類的本機標記被帶到其他裝置。這些檔案沒有註冊的 `DocumentKind`，合併時視為不透明檔案（內容不同 → 衝突副本）；外掛要自己設計成不會衝突（例如每台裝置只寫自己的檔案）。
- `VaultFS.deviceID()`：第一次呼叫時產生 UUID 寫入 `.easynotes/device-id`（不同步）。舊版存在 `sync.sqlite` 的 device 會先搬過來，id 不變。檔案被刪掉只會換一個新 id，用到 id 的資料（例如複習紀錄）多出一個新檔案，不會遺失。

**索引與內容修正（3a）**：

- `IndexContributor`（Core，無 UI）：外掛從檔案內容抽出自己的資料，Core 存在通用的 `records(contributor, path, key, value)` 表，`value` 是外掛自訂的 JSON 字串，Core 不解讀。外掛的 `version` 改變時整個索引重建。查詢只有「某 contributor 的全部 records」與「某 key 出現在哪些檔案」，複雜的查詢由外掛在記憶體中做（個人 Vault 的卡片數量級是數千）。
- `ContentFixer`（Core，無 UI）：外掛在背景改寫檔案內容，App 寫回後照一般路徑索引與同步。App 只對**本機產生**的變動（App 內編輯、外部工具）呼叫，不處理同步拉下來的內容；**開啟中的檔案不改寫**，離開該檔案後才處理，所以不會在打字或注音組字中插入文字，也不必跨 Bridge。連續變動合併後（約 1.5 秒）才執行，讓 Claude Code 搬移內容時兩個檔案都寫完再判斷。
- `addVaultGuide`：Vault 根目錄沒有 `CLAUDE.md` 時，App 以各外掛提供的段落建立它；已存在就不改寫（使用者可以自行編輯）。

**伴隨檔（Phase 5）**：`companionOf` 回傳主檔路徑的檔案（例如 `x.pdf.ink`）。`KindRegistry.mainFile(ofCompanion:)` / `companionPath(_:from:to:)`、`VaultFS.companions(of:)` / `companionMoves(from:to:)` 是共用的查詢。檔案樹（`VaultFS.scan`）、`allFiles`、`VaultIndex.files` / `search`、`SyncEngine.recentlyDeleted` 預設不含伴隨檔；`VaultFS.fileStats` 含（照常索引與同步）。`VaultFS.rename` / `trash` 一併處理伴隨檔；`SyncEngine` 推斷出外部改名時搬移伴隨檔、還原主檔時還原伴隨檔。

**Registry 分兩層**：Registry 分兩層。Core 只有無 UI 的 KindRegistry，給 Vault、Index、Sync 使用；PluginRegistry 需要 SwiftUI（addEditor 回傳 View），所以放在 EasyNotesUI。外掛不能 import App，因此 VaultStore 中 Markdown 專屬的邏輯（改名時更新連結、外部修改推給編輯器、自動完成清單）改走 DocumentKind.renameLinks 與 EditorController。

**圖形預覽與嵌入（Phase 4）**：

- `DocumentPreview`（EasyNotesUI）新增 `image: Data?`（PNG）：圖形類外掛（白板、之後的 PDF）在 `makePreview` 中於背景畫出縮圖，依 hash 快取成 `<hash>.png`（與 `<hash>.json` 同資料夾，JSON 只記 `hasImage`，不放 base64）；Core 不認識圖的內容。白板縮圖的預設白色背景畫成透明，深色模式由顯示端反相（`invert` + `hue-rotate(180deg)`，與 Excalidraw 深色主題相同）。
- `embed:///<Vault 相對路徑>`（每段 percent-encode，與 `vault://` 相同）：WebEditorHost 新增的 `WKURLSchemeHandler`，經 `DocumentSession.embedImageReader`（App 的 VaultStore 實作，預設回傳 nil）回傳該檔案預覽的 `image`（依內容 hash 快取，檔案沒有註冊預覽或沒有圖時回 404）。Markdown 的 `![[x.excalidraw]]` 只放 `<img src="embed://…?h=<hash>">`，不經 Bridge；hash 變了 URL 就變，WebView 自動重新載入。Phase 6 的 `![[x.csv]]` 沿用同一個 scheme。

**預覽（2.5c）**：`DocumentPreviewProvider` 分兩段。`makePreview(Data) -> DocumentPreview` 在背景執行，結果可序列化，依內容 hash 快取在 `.easynotes/cache/preview/<kind>-v<version>/<hash>.json`；`view(_:)` 在主執行緒用原生 SwiftUI 渲染。沒有註冊預覽的類型顯示骨架佔位。

待抽出：Core 不含任何檔案類型，但 `VaultIndex.clean()` 的片段清理仍是 Markdown 語法，第二個有文字的外掛需要時再抽成擴充點。


## 同步設計

同步層只看 file id、path、內容 hash 與版本，不認識檔案類型；合併交給各 `DocumentKind`。實作分工見下方；進度見 Roadmap Phase 2。

三個關鍵決定：

1. **穩定 file id**：檔案身分是 id，path 只是屬性。改名與搬移只更新 path，不變成「刪一個、新增一個」，歷史與合併基準都保留。
2. **版本檢查在伺服器端**：用 Postgres function（RPC）在一個交易內比對並遞增 version，兩台裝置同時上傳也不會互相覆蓋。
3. **三方合併是同步的一部分**：Markdown 的 diff3 是同步的必要條件。Mac 上 Claude Code 寫檔、iPad 同時在編輯是常態，只有衝突副本不夠用。

實作決定：

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
- App 內改名直接更新 path；外部工具（Finder、Claude Code 的 `mv`）改名時，VaultWatcher 會看到「刪除 + 新增」，若兩者 hash 相同就推斷為改名並保留 file id。推斷失敗最多失去歷史，不會遺失內容。主檔被推斷為改名時，留在原地的伴隨檔一起搬過去（經 `Hooks.didChange` 通知 App）。

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
| 早期 Debug build（實測，未含 Supabase） | 1.8 MB |
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
- **檔案監看**：FSEvents 只重掃事件帶來的路徑。不對整個 Vault 做 stat，Claude Code 一次改很多檔案時只處理那些路徑。
- **無輪詢**：Swift 端沒有計時器輪詢；JS 端不跑 interval 或 rAF 迴圈；白板只在內容變動時重繪，不用 `TimelineView`。
- **執行緒**：索引與 hash 用 `.utility` QoS。

### 驗收情境（Instruments）

1. 連續打字 5 分鐘（記憶體不持續成長、CPU 在停止輸入後回到閒置）
2. PDF 快速翻完 200 頁（記憶體穩定）
3. Claude Code 一次修改 50 個檔案（只重新索引這 50 個，不重掃整個 Vault）
