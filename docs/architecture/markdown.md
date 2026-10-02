# Markdown

- **做**：Live Preview、`[[連結]]` + 反向連結、`[[` 自動完成、連結改名、標籤、FTS5 搜尋、`![[x.excalidraw]]` / `![[x.csv]]` 嵌入預覽、卡片語法標示、Writing 模式（專注、打字機捲動、字數）。
- **實作**：CM6 + Lezer 增量解析；單一預熱 WebView，切換筆記只換 `EditorState`；Bridge 協定見下方。
- **嵌入**：`LinkTarget` 帶 `hash`（隨 `setLinkTargets` 推送，只在索引變動時送出，不在打字路徑上）；CM6 的 `EmbedWidget` 依完整路徑或「檔名.副檔名」找到目標，放 `<img src="embed:///…?h=<hash>">`。圖片副檔名仍走 `vault://`；`.md` 不嵌入；找不到目標時顯示原始語法。hash 改變時只換 `src`，舊圖留到新圖載入完成。點一下開啟目標，⌘ / ⌥ 點擊顯示原始 md。深色模式用 CSS `invert(93%) hue-rotate(180deg)`。
- **合併**：diff3 三方合併。非重疊修改自動合併，重疊才產生衝突副本。編輯中收到遠端變更時，用 `applyRemote` 套用到 CM6，保留游標與 undo。


## Bridge 協定（Swift ⇄ WebView）

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
