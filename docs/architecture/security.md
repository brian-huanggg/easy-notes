# 資安設計與威脅模型

@Brian

**本文件只放**：資產、信任邊界、威脅模型、各邊界現在採用的防護與其理由、不可違反的安全不變條件。**不放**審查進度與待修項目（寫在 [Roadmap](../Roadmap.md)「資安審查」）、版本變更（寫在 [Changelog](../Changelog.md)）。

EasyNotes 是個人使用、不上架的 App（見 [README](./README.md)），所以威脅模型以「自己的資料不被別人或惡意檔案取得、改寫、毀損」為主，不處理多租戶與合規。

## 資產

| 資產 | 位置 | 為什麼重要 |
| --- | --- | --- |
| 筆記內容 | Vault 內的 `.md` / `.excalidraw` / `.pdf` / `.csv` | 可能含密碼、個資、工作內容；是唯一真相 |
| 登入狀態（Supabase session） | Keychain（supabase-swift 預設） | 取得即可讀寫雲端 Vault |
| 索引資料庫 | `.easynotes/` 內的 SQLite（可重建） | 含全文，等同筆記內容的副本 |
| 同步中繼資料 | `files` 資料表、Storage `vault` bucket | 雲端上的筆記副本 |
| 簽署身分與 TestFlight 憑證 | 開發機 Keychain、Apple 帳號 | 偽造 App 發佈 |

## 信任邊界與攻擊者

```
惡意檔案（md / pdf / csv / excalidraw，來自別人或下載）
        │ 解析、渲染
        ▼
  ┌── App ───────────────────────────────┐
  │ WebView（JS）──Bridge──► Swift 外殼   │
  │ 外掛（原生解析）──► Vault（檔案系統）  │
  └──────────────┬───────────────────────┘
                 │ HTTPS（supabase-swift）
                 ▼
        Supabase（Auth · Postgres · Storage · Realtime）
```

| 攻擊者 | 能做的事 | 主要防線 |
| --- | --- | --- |
| 惡意內容（別人傳來的筆記、PDF、匯入檔） | 讓渲染器執行腳本、讀寫 Vault 外的檔案、讓 App 崩潰或卡死 | WebView 隔離、Bridge 白名單、解析器健壯性 |
| 同機其他程式 | 讀 Vault、索引、日誌、剪貼簿 | 檔案權限、FileVault、日誌不含內容 |
| 網路中間人 | 竊聽或竄改同步流量 | TLS（ATS 預設）、內容定址 hash 驗證 |
| 其他 Supabase 使用者 | 讀寫別人的列與 blob | RLS、Storage policy |
| 被入侵的雲端或帳號 | 竄改路徑、內容、刪除 | 客戶端不信任遠端資料：驗證路徑與 hash |
| 供應鏈 | 惡意的 SPM / npm 套件 | 鎖定版本、審計、最少依賴 |
| 遺失的裝置 | 讀 Vault | 全碟加密（FileVault / iOS 資料保護）；App 本身不另加密 |

**不防的**：已取得使用者登入 session 的惡意程式、被完全入侵的作業系統、使用者主動打開並信任的外部連結。檔案即真相、本地明文是刻意的取捨（Claude Code 與其他工具要能直接讀寫），所以靜態加密交給系統層。

## 安全不變條件

下列規則是審查與修改時的判準，違反即為漏洞：

1. **Vault 路徑一律是相對路徑，且永遠停在 Vault 內。** 任何來源（Bridge、遠端同步、`vault://`、檔案名稱）給的路徑，在轉成檔案 URL 之前都拒絕絕對路徑、`..`、`.` 段與解開 symlink 後離開 Vault 的結果。
2. **不信任遠端資料。** 從 Supabase 取得的 `path` 要驗證後才可寫入；下載的 blob 要比對 SHA-256 與其 `hash` 才可套用或快取。
3. **WebView 沒有通用原生能力。** Bridge 只暴露各外掛定義的具名訊息；沒有「讀任意檔」「開任意 URL」「執行命令」這類通用入口。JS 傳來的所有欄位都當成不受信任的輸入。
4. **WebView 只載入 App 內的資源與自訂 scheme。** 不載入遠端頁面或腳本；頁面內的外部連結交給系統瀏覽器，不在 WebView 內導覽。
5. **憑證只放 Keychain；程式與 repo 只有公開金鑰。** App 內只允許 Supabase publishable（anon）key，不得出現 `service_role` 或任何私鑰；`.env*` 不進版控。
6. **寫入雲端一律經 `commit_file`。** 資料表沒有 insert / update / delete policy；Storage 只增不覆寫、不刪除。
7. **日誌與崩潰資訊不含筆記內容。** DEBUG 以外不印訊息內容；`os_log` 使用者資料標 `.private`。
8. **測試掛鉤只在 DEBUG。** Release 忽略 `-EasyNotesVaultRoot` 等啟動參數（見 [README](./README.md)「測試」）。

## 各邊界的現行設計

### Vault（檔案系統）

- macOS：`~/Documents/EasyNotes`，**不開沙盒**（理由見 [README](./README.md)「Vault 位置」：Finder 與 Claude Code 要能直接讀寫）。沒有沙盒就沒有 OS 層的檔案隔離，所以路徑規則（不變條件 1）完全由程式碼負責。
- 寫入是 atomic（先寫暫存檔再替換），不留半個檔案。
- `vault://` scheme 只回應 Vault 內的相對路徑，拒絕 `..`、`.` 與空路徑，query 與 fragment 先剝掉；`embed://` 套用同一套規則；`symbol://` 只回傳 SF Symbol 圖。
- `.easynotes/device-id` 不同步。

### WebView 與 Bridge

- 只有 Markdown 與 Sheets 兩個外掛使用 WebView，共用 `WebEditorHost`：單一 `bridge` message handler，訊息是 `{type, …}`，由外掛的 `onMessage` 依 `type` 分派。
- 頁面以 `loadFileURL(_, allowingReadAccessTo:)` 載入，讀取範圍限於外掛 bundle 內該頁面所在資料夾；Vault 的圖片不走 `file://`，只走 `vault://`（上節的路徑檢查）。
- **導覽**：`WebEditorHost` 的 navigation delegate 只放行頁面本身；任何其他導覽取消，使用者點擊的 `http(s)` / `mailto` 交給系統開啟。
- **CSP**：兩個頁面以 `<meta>` 設定 `default-src 'none'`，只放行同資料夾的腳本（`'self'`）、同資料夾的樣式與字型（KaTeX）、inline 樣式（CodeMirror 與注入的主題需要）、`vault:` / `embed:` / `symbol:` / `data:` 圖片；`connect-src 'none'`，沒有遠端資源、沒有 inline 腳本。新增外掛的 WebView 頁面必須套用同一份 CSP。
- Swift → JS 用 `callAsyncJavaScript` 傳具名參數，不拼接字串；注入的語言與主題以 JSON 編碼成字面值。
- Bridge 傳來的任何路徑都不直接當寫入目標：Markdown 的 `changed` 只接受該編輯器載入過的文件 id，且通過 `VaultFS.isSafe`；`VaultStore.write` 再檢查一次。連結標題建立新檔時經 `VaultFS.safeFileName`，只會是單一路徑段。
- Bridge 不在打字熱路徑上（見 [markdown.md](./markdown.md)），所以對訊息的驗證不影響手感。
- 筆記內容在 WebView 內以 CodeMirror 的 decorations 渲染，不把使用者文字當 HTML 插入；`innerHTML` 只用於 App 內建的 SVG 圖示常數。

### 同步（Supabase）

- **身分**：Supabase Auth；`files` 的 RLS 只允許 `select` 自己的列（`user_id = auth.uid()`）。
- **寫入**：只能呼叫 `commit_file`（`security definer`、`search_path = ''`）；`anon` 與 `public` 無執行權限；以 `auth.uid()` 決定列的擁有者，client 無法指定 `user_id`。
- **Blob**：Storage bucket `vault` 為私有，路徑 `<user_id>/<hash>`，policy 以資料夾名稱比對 `auth.uid()`；只有 `select` 與 `insert`，沒有 `update` / `delete`，所以已上傳的內容無法被覆寫。
- **內容定址**：hash 是 SHA-256，同一 hash 重複上傳視為成功；因此下載後的內容必須自己驗證 hash（不變條件 2）。
- **軟刪除**：保留 30 天後由 `pg_cron` 清除列；Storage 內容不刪（可能被其他版本共用）。
- **金鑰**：App 內是 publishable key，權限完全由 RLS 與 RPC 決定。
- **傳輸**：預設 ATS（HTTPS），不設定例外網域。

### 外掛與檔案解析

- 外掛是編譯期 SPM 模組，沒有執行期載入程式碼，沒有第三方外掛介面。
- 所有解析器（Markdown、Excalidraw JSON、`.pdf.ink`、CSV / TSV、Anki 匯出入、`.jsonl` 複習紀錄）面對的都是可能被竄改的檔案：必須容忍畸形輸入、不崩潰、不無限迴圈、不因巢狀或大小而耗盡記憶體；未知欄位原樣保留，不當成指令。
- **成本上限**：任何對檔案內容的處理都必須是線性（或有明確上限）的。同步合併的 `Diff3` 以估計的 diff 成本設上限，超過就當衝突、留衝突副本；`[[…]]` 的正則不允許目標或別名包含 `[`，避免 `[[[[…` 造成平方成本。
- **Bridge 的數值**：欄位索引、row id 等來自 JS 的整數一律檢查範圍（`SheetDocument.maxColumns`、row id 限 53 位元），超出就拒絕，不得用來索引陣列或配置記憶體。
- PDF 由 PDFKit 渲染，App 不改動原檔，標註寫在旁檔。

### 發佈與簽署

- iOS / iPadOS：TestFlight（Apple 簽署與審查）。
- macOS：DMG 手動安裝，沒有自動更新通道，所以沒有「更新被劫持」這條攻擊面；新增更新機制時必須驗簽章（例如 Sparkle 的 EdDSA）。
- macOS 目前未啟用 Hardened Runtime 與沙盒；個人使用、不公證。若要給他人安裝，必須先啟用 Hardened Runtime 並公證，且盤點所需的例外 entitlement。
- Entitlements 維持最小：目前只有 Sign in with Apple。

### 供應鏈

- Swift：`Package.resolved` 鎖定版本；npm：`package-lock.json` 鎖定，打包後的 JS 內含在 App 內（不在執行時下載）。
- 新增依賴前確認授權、維護狀態與是否有已知漏洞；優先選依賴少的套件。

## 審查方法

審查流程、工具與每次的發現寫在 Roadmap「資安審查」；本文件只定義「什麼算安全」。每次審查以上面的不變條件逐條驗證，並在發現新的攻擊面時回來更新本文件的邊界與不變條件。
