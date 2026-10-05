# EasyNotes 架構與技術方案

@Brian

**本文件只放**：現在的設計與取捨理由（做什麼、為什麼這樣做）。**不放**進度與驗收（寫在 [Roadmap](../Roadmap.md)）、版本變更（寫在 [Changelog](../Changelog.md)）。被推翻的決定直接刪除，歷史看 git；章節中的 Phase / 子階段編號（3b、4c…）只是出處標籤，對應 Roadmap 的項目。

**怎麼讀**：本檔放跨功能的設計原則、技術選型、模組結構與依賴規則；每個功能一個檔，整份讀即可。先看 Roadmap「狀態總覽」的「設計」欄找到對應檔；只有新增外掛、改 Core 或擴充點、跨外掛的修改才需要讀本檔與 `core.md`。

| 工作 | 檔案 |
| --- | --- |
| 新增外掛、改 Core 或擴充點、同步與合併、Claude Code 整合、大小 / 記憶體 / 耗電預算 | [core.md](./core.md) |
| 外殼、導覽、列表、文件頭、設計系統 | [ui.md](./ui.md) |
| Markdown、Bridge 協定、打字手感 | [markdown.md](./markdown.md) |
| 白板 | [whiteboard.md](./whiteboard.md) |
| PDF 手寫與標註 | [pdf.md](./pdf.md) |
| 表格 | [sheets.md](./sheets.md) |
| 卡片與複習 | [flashcards.md](./flashcards.md) |
| 多語言、字串寫法、不翻譯的字串 | [translation.md](./translation.md) |
| 威脅模型、信任邊界、安全不變條件（WebView / Bridge、同步、檔案解析、簽署） | [security.md](./security.md) |

EasyNotes 是個人使用的知識庫 App（不上架、不商業化）。核心只負責檔案、同步、索引與外掛註冊；Markdown、白板、PDF 手寫、CSV、Flashcards 都是編譯期外掛。所有資料都是開放格式的真實檔案，透過 Supabase 在 iOS、iPadOS、macOS 間同步，Claude Code 可以直接讀寫。

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
| 非功能 | App < 100 MB（預估 15–30 MB）、記憶體與耗電有預算、離線可用、同步可靠（見 [core.md](./core.md)「非功能預算」） |
| 使用範圍 | 個人使用：不上架、不商業化（授權限制因此寬鬆，但仍優先選 MIT / BSD 套件） |
| Vault 位置 | macOS：~/Documents/EasyNotes（可見、不開沙盒）；iOS：App 的 Documents（「檔案」App 可見） |
| 發佈 | iOS / iPadOS：TestFlight（`upload-testflight.sh`）；macOS：DMG（`make-dmg.sh`）加 Sparkle 自動更新（見「發版流程」）。macOS 不開沙盒，所以不能走 TestFlight / Mac App Store；App Store Connect 關閉「iPad App 可在 Mac 上使用」，避免 Mac 裝到 iPad 版（沙盒 Vault、iOS UI） |

## 設計原則

1. **檔案即真相**：每筆筆記是磁碟上的一個檔案，資料庫只是可重建的索引。刪掉索引不會遺失任何內容。
2. **開放格式**：`.md`、`.excalidraw`、`.csv`、`.pdf` + 標註旁檔，都能被其他工具直接打開；App 不改寫使用者的格式，未知欄位原樣保留。
3. **本地優先**：所有操作先寫本地，離線完全可用；同步在背景進行。
4. **核心不認識檔案類型**：核心只有檔案（Vault）、同步、索引與外掛註冊。Markdown 也是外掛，和其他外掛走同一套介面。
5. **外掛依功能切分、編譯期組裝**：外掛只依賴 Core、彼此不依賴；用 WebView 或原生是外掛內部的實作選擇。
6. **原生外殼、合適的編輯面**：導覽、資料、同步、手寫用 Swift；有成熟套件的編輯面（CodeMirror 6、RevoGrid）用 WebView。
7. **為 Claude Code 優化**：格式讓 Claude 直接讀寫；外部修改即時偵測並同步；Vault 根目錄的 `CLAUDE.md` 說明慣例。

## 技術選型決策

決策：Swift 做外殼與資料層；Markdown 與 CSV 用 WebView（CodeMirror 6、RevoGrid）；手寫、白板、PDF 用原生（PencilKit、PDFKit、SwiftUI Canvas）。白板：不再使用 Excalidraw 的 Web runtime，只保留 .excalidraw 檔案格式，白板改為原生自建。Notion、Obsidian、Typora 的編輯器都是 Web 技術，流暢度取決於工程手法，而非原生與否。

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

現行決定：**保留 WebView + Bridge，但只用在 Markdown 與 CSV 兩個外掛。** S1 已在實機驗證注音組字與效能；Bridge 不在打字路徑上；WebKit 是系統框架，不增加 App 體積。白板、PDF、複習介面、嵌入預覽與白板上的筆記卡片一律原生渲染，絕不為每張卡片開一個 WebView。只有在 iPhone 實測發現 WebView 記憶體導致背景被系統關掉時，才重新評估原生文字引擎（例如 STTextView）。

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

```
UI 層
  App（SwiftUI 外殼）          外掛（編輯器、面板、預覽）
  EasyNotesUI（PluginRegistry、WebEditorHost、DesignSystem）
        │ 只透過 Vault / Registry 存取資料
核心層（EasyNotesCore，無 UI 依賴）
  KindRegistry
  Vault（VaultFS、VaultWatcher） ──► Index（SQLite + FTS5）
        │                        └─► SyncEngine ──► SyncBackend
        ▼
  磁碟上的檔案（唯一真相）
Supabase（SyncBackend 的實作，由 App 組裝）
  Auth · Storage · Postgres（commit_file RPC）· Realtime
```

**Vault 是唯一真相**，Index 與 Sync 都從它衍生。核心只透過 PluginRegistry 認識外掛；外掛的編輯器（不論 WebView 或原生）永遠不直接碰網路，讀寫檔案一律經過 Vault。

### 模組結構

```
Packages/
  EasyNotesCore/     核心（不認識任何檔案類型）
    EasyNotesCore    Vault、Index、Sync、DocumentKind 與 KindRegistry（無 UI 依賴，可單元測試）
    EasyNotesUI      PluginRegistry、EasyNotesPlugin、DocumentSession、EditorController、
                     WebEditorHost（預熱、Bridge、本地資源）、DesignSystem（tokens、共用元件）、
                     手寫工具列（InkSettings、StraightLineAssist，白板與 PDF 共用）
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
- **共用函式庫**（目前只有 `ExcalidrawKit`）：兩個以上外掛需要同一份格式程式時才抽出。它不是外掛：不依賴 EasyNotesUI 的 Registry、不註冊 Kind / 編輯器 / 選單，只提供模型、轉換與渲染；也不依賴任何外掛。抽出原因：PDF 標註需要白板的元素模型、合併、筆畫轉換與渲染器，複製會讓兩份程式漂移，併進 KindWhiteboard 會讓 PDF 無法獨立移除，所以抽成 `ExcalidrawKit`。
- **Core 永遠不 import 外掛**；App target 負責組裝。
- **外掛是編譯期的 SPM 模組**，不在執行時期載入程式碼。
- **WebView 或原生是外掛內部的實作選擇**。WebView 外掛共用 EasyNotesUI 的 WebEditorHost，仍遵守「打字熱路徑不跨 Bridge」。
- **Markdown 也是外掛**，沒有特權通道，用來驗證外掛介面是否夠用。
- **卡片語法屬於 Vault 的 Markdown 方言**，所以語法標示由 Markdown 外掛負責；Flashcards 只負責解析、排程與複習。這樣不必在執行時期把 JS 擴充注入別的外掛。


## 外掛功能設計

每個外掛決定自己的格式、編輯器與合併策略。「不做」的項目是刪減後的決定，不是遺漏。

| 外掛 | 格式 | 編輯器 | 同步合併 |
| --- | --- | --- | --- |
| Markdown | `.md` + YAML frontmatter | CodeMirror 6（WebView） | diff3 三方合併（以行為單位） |
| Whiteboard | `.excalidraw`（官方 JSON） | PencilKit + CALayer 結構層（原生） | 依元素 `id` + `version` |
| PDF | `.pdf`（不改動）+ `.pdf.ink`（JSON，伴隨檔） | PDFKit + 每頁 PencilKit 疊層（原生） | PDF 不合併；旁檔依頁 + 元素 `id` |
| Sheets | `.csv`、`.tsv`；欄寬等放 `.csv.meta.json` | RevoGrid（WebView） | diff3（以記錄為單位，同一記錄再以儲存格合併） |
| Flashcards | 卡片寫在 `.md`；紀錄 `.easynotes/srs/<deviceId>.jsonl`；設定 `.easynotes/srs/<deviceId>.config.json` | 原生複習介面 | 卡片跟著 md；紀錄與設定都是各裝置各寫，永不衝突；設定以欄位 LWW 合成 |

### 跨外掛功能

- `[[筆記]]` 連結；`![[圖.excalidraw]]`、`![[表.csv]]` 在 md 內嵌入預覽，預覽由各外掛向 Registry 註冊的 DocumentPreviewProvider 提供。
- 每個 `DocumentKind` 的 `index()` 抽出純文字與連結，所以白板內的文字元素也能搜尋、也會出現在反向連結（手寫筆畫不索引）。
- App 設定放 `.easynotes/`（類似 `.obsidian/`），跟著 Vault 同步。
- 介面語言（zh-Hant、English (US)）：每個模組自帶字串檔，Vault 內的路徑、檔名慣例與同步協定的字串不隨語言改變，見 [translation.md](./translation.md)。

## 發版流程

版本號、Changelog、tag、更新通道都由 commit 驅動，不手改。

- **Commit 訊息**：Conventional Commits，由 `.githooks/commit-msg`（commitlint，`commitlint.config.mjs`）強制；root 的 `npm install` 會設定 `core.hooksPath`。type 決定 Changelog 分類：`feat` → Added、`fix` → Fixed、`perf` → Changed、`security` → Security；`docs` / `refactor` / `test` / `chore` / `build` / `ci` / `style` / `revert` 與 merge commit 不進 Changelog。因此 `feat` / `fix` / `perf` / `security` 的 subject 就是使用者看到的那一行：繁體中文、寫使用者看得到的變化。
- **Changelog**：`docs/Changelog.md` 由 git-cliff（`cliff.toml`）從上個 tag 以來的 commit 產生，格式是 Keep a Changelog。想手寫的版本，在發版前放一個 `## [Unreleased]` 區塊，會直接改名成該版本，不再產生。`scripts/changelog.py` 負責讀寫這個檔案。
- **版本號的唯一來源**是 `project.yml` 的 `MARKETING_VERSION`（Info.plist、Sparkle、TestFlight 都讀它）；build 號碼（`CURRENT_PROJECT_VERSION`）是打包時的時間戳，Sparkle 靠它判斷新舊，所以必須遞增。`scripts/release.sh` 負責測試、Changelog、`MARKETING_VERSION`、「新功能」內容、commit 與 tag，不 push；版本號預設依 commit 類型決定。
- **`scripts/publish-release.sh`** 對 HEAD 上的版本 tag 做：打包 DMG、用 Sparkle 的 `generate_appcast` 簽章、push、建立 GitHub Release（附 DMG 與 `appcast.xml`）；`--testflight` 另外上傳 iOS / iPadOS。push 與建立 Release 是對外的動作，預設會先確認。
- **Sparkle**（`Packages/AppUpdater`）：只有 macOS 連結（target 的平台條件；XcodeGen 的 package 依賴不能依平台過濾）。`SUFeedURL` 指向最新 Release 的 `appcast.xml`（`releases/latest/download/…`），所以 repo 必須是 public，private repo 的 Release 對使用者的 App 讀不到。更新以 EdDSA 簽章驗證：公鑰是 `project.yml` 的 `SPARKLE_PUBLIC_ED_KEY`（空的時候 App 不啟動更新檢查），私鑰在發版那台 Mac 的 keychain（`scripts/sparkle-tools.sh generate-keys` / `export-key`；遺失就無法再發更新給已安裝的版本，要備份）。更新說明是 Changelog 該版的區塊，內嵌在 appcast。
- **「新功能」視窗**：`scripts/release.sh` 把 Changelog 該版的區塊轉成 `App/Resources/WhatsNew.json` 打包進 App（Changelog 是唯一來源，只在發版時更新）。啟動時比對 `lastSeenVersion`（UserDefaults）與目前版本，較新才顯示；沒有紀錄時，全新安裝（本次啟動才建立範例內容）不顯示，其他情況（從這個功能出現之前的版本更新）顯示。JSON 的版本與目前版本不同就不顯示。UI 測試不顯示。內容是繁體中文（Changelog 的語言），視窗標題與章節名經過 `L("…")`。Mac 的「說明」選單可以再開。

## 測試

分層：越下層越多、越快；E2E 只驗證「接起來」的部分，不重測下層已經測過的邏輯。

| 層 | 內容 | 指令 |
| --- | --- | --- |
| 單元 | 各 Package 的 `swift test`（Core 的 Vault、索引、同步引擎用假 backend；外掛的格式、合併） | `swift test` |
| Web | CM6 的 rebase、換行、注音組字（Chromium 模擬輸入法） | `npm test`、`node test/ime.e2e.mjs` |
| 整合 | SupabaseSync 對本地 Supabase 的 RPC 併發與 RLS | `scripts/test-sync.sh` |
| E2E | XCUITest 從外部操作 App（macOS、iPad 模擬器） | `scripts/test-e2e.sh` |
| 實機 | 注音（WebKit）、Apple Pencil、耗電與記憶體 | Roadmap 的手動清單 |

E2E 的設計：

- **斷言看檔案，不看畫面**：每個測試建立自己的暫存 Vault，App 以 DEBUG 啟動參數 `-EasyNotesVaultRoot` 開啟它；測試直接讀寫磁碟上的檔案，扮演 Finder / Claude Code，並以檔案內容驗證 App 的操作。iOS 模擬器的 Vault 放在 `SIMULATOR_SHARED_RESOURCES_DIRECTORY`（模擬器內的 App 都能讀寫）。
- **測試約定只有一份**：啟動參數名稱（`LaunchKey`）與 accessibility identifier（`A11yID`）寫在 `App/Support/UITestContract.swift`，App 與測試 target 編譯同一份檔案。測試只用 identifier 找元素，不依賴介面文字（翻譯不會讓測試壞掉）；含路徑的 identifier 直接帶 Vault 相對路徑。
- **測試掛鉤只在 DEBUG**（`App/Support/TestHooks.swift`）：Release 忽略所有啟動參數，Vault 位置與同步都是正常行為。
- **同步 E2E 不需要網路**：`EasyNotesTestSupport` 的 `FolderSyncBackend` 以資料夾當遠端（`commit` 語意與 `commit_file` 相同、`flock` 跨程序互斥），App 以 `-EasyNotesSyncFolder` 使用它、以監看資料夾取代 Realtime；測試程序用同一個資料夾跑自己的 `SyncEngine`，扮演另一台裝置。Supabase 本身由整合測試負責。
- **只輸入 ASCII**：XCUITest 的 `typeText` 不經過輸入法，測不到注音組字；注音由 Web 層的 Chromium 模擬與實機清單負責。
- **WebView 只測接線**：編輯器邏輯在 Web 層測；E2E 只確認打字經 Bridge 存檔、外部修改出現在開著的編輯器。
- **範圍**：Mac 與 iPad（側邊欄版面）。iPhone 的底部分頁另有一套畫面，目前不在 E2E 範圍。
