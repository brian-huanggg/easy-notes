# Markdown

- **做**：Live Preview、`[[連結]]` + 反向連結、`[[` 自動完成、連結改名、標籤、FTS5 搜尋、`![[x.excalidraw]]` / `![[x.csv]]` 嵌入預覽、卡片語法標示、可直接編輯的表格、數學公式（LaTeX）、屬性面板、在筆記中尋找、Writing 模式（專注、打字機捲動、字數）。
- **實作**：CM6 + Lezer 增量解析；單一預熱 WebView，切換筆記只換 `EditorState`；Bridge 協定見下方。
- **嵌入**：`LinkTarget` 帶 `hash`（隨 `setLinkTargets` 推送，只在索引變動時送出，不在打字路徑上）；CM6 的 `EmbedWidget` 依完整路徑或「檔名.副檔名」找到目標，放 `<img src="embed:///…?h=<hash>">`。圖片副檔名仍走 `vault://`；`.md` 不嵌入；找不到目標時顯示原始語法。hash 改變時只換 `src`，舊圖留到新圖載入完成。點一下開啟目標，⌘ / ⌥ 點擊顯示原始 md。深色模式用 CSS `invert(93%) hue-rotate(180deg)`。
- **換行符**：檔案的換行全部是 `\r\n` 時，`EditorState` 加上 `lineSeparator`，寫回用 `sliceDoc()`，換行逐位元組保留；混合的換行照 CM6 預設統一成 `\n`。插入多行文字一律轉成 `Text`（`lineBreak.ts` 的 `lines`），不直接插入含 `\n` 的字串；`applyRemote` 在 doc 座標上算差異，換行符改變時重建 state。
- **注音組字**：組字中（`view.composing`）不改動文件：存檔延後（`flush` 重新排程），`applyRemote` 收到的內容先暫存，`compositionend` 之後等 CM6 從 DOM 讀進選好的字（約 50ms）再套用。組字中改動涵蓋游標的範圍會打斷輸入法，注音符號會留在文件裡。
- **表格**（`table.ts`、`tableWidget.ts`）：文件最上層的 GFM 表格顯示成格子（block widget，StateField），仿 Notion 直接點格子編輯；沒在編輯的格子渲染格內 md（粗體、程式碼、連結、公式、`<br>`），編輯時換回原始文字。Tab / Shift-Tab、Enter、↑↓ 移動，最後一格 Tab 或最後一列 Enter 新增一列，Esc 離開到表格下一行；底部、右側「+」新增列欄，格子的「⋯」選單插入、移動、刪除列欄與設定對齊。內容列第一格左側、標題列每格上方有拖曳把手（hover 時出現，觸控裝置常駐半透明）：以 Pointer Events 拖曳，越過相鄰列欄的中線就移動插入線，放開後以 `moveRow` / `moveColumn` 重寫表格（對齊跟著欄走）；沒拖動（< 4px）視為點一下，開啟該格的「⋯」選單。標題列固定在最上面，不能拖。把手放在 `.cm-table-scroll` 的上方與左側內距（負 margin 抵銷，表格仍與內文切齊；左側用 scroller 的 gutter），不會被水平捲動裁掉。改一格只替換那一格的文字（其餘位元組不變），列欄操作才重寫整個表格（`| a | b |`、`| --- |` 的標準格式）。格子是 widget 內的 `contenteditable="plaintext-only"`，鍵盤、滑鼠、組字事件都不交給 CM6（`ignoreEvent`）；`input`（非組字中）、`compositionend`、`focusout` 才寫回，注音組字完全由瀏覽器處理。widget 用 `updateDOM` 更新同一份 DOM，正在打字的格子不被重建；事件處理一律在當下以 `posAtDOM` 從文件重讀表格，不保存可能過期的模型。編輯器有焦點且游標進入表格範圍（例如方向鍵移入、選單的「編輯 Markdown 原始碼」）時顯示原始 md。引言、清單內的表格維持原始 md。
- **數學公式**（`math.ts`）：擴充 Lezer markdown 的語法：`$…$` 行內、`$$…$$` 區塊（可同一行），公式內不再解析粗體、標籤、卡片等標記。行內規則同 Pandoc：開頭 `$` 後面與結尾 `$` 前面不能是空白、結尾 `$` 後面不能是數字（「$5 和 $10」不是公式）；區塊還沒打結尾 `$$` 時到空行為止，這種沒有結尾的區塊一律顯示原始碼、不渲染（剛打完 `$$` 換行時那一行不會變成空白公式）；在只有 `$$` 的開頭行尾按 Enter 會補上結尾 `$$`，游標放在中間（`mathKeymap`，`Prec.highest`，比 markdown 的接續清單先處理）。以 KaTeX（MIT）渲染：行內公式由 Live Preview 在非游標行換成 widget，區塊公式是 block widget（StateField），游標在區塊內時顯示原始碼並在下方即時預覽；游標在行內公式裡（原始碼）時，下方浮出渲染結果（CM6 tooltip，內容與位置不變時沿用同一個 tooltip）。KaTeX 不打包進 `editor.js`：`build.mjs` 把 `katex.min.js`、CSS 與 woff2 字型複製到 `Resources/Editor/katex/`，文件第一次出現公式才以 `<script>` 載入（載入前顯示原始碼），同一段公式的 HTML 有快取。已知限制：Swift 端的卡片解析不認識公式，公式內的 `{{…}}` 仍會被當成克漏字。
- **屬性面板**（`frontmatter.ts`、`properties.ts`）：frontmatter 的頂層欄位顯示在標題下方（仿 Obsidian 的 Properties），可以改值、改名、換型別（文字、清單、核取方塊、日期）、新增與刪除；`icon`、`cover` 由文件頭處理，不在面板顯示。型別由值判斷：`true` / `false` 是核取方塊、`YYYY-MM-DD` 是日期、`[a, b]` 或下一行起的 `- a` 是清單（`tags`、`aliases`、`cssclasses` 一律是清單），巢狀結構與多行字串只顯示、點一下改編輯原始 YAML。寫回只替換該欄位的行，其餘行（含註解、不認識的欄位）逐位元組保留；清單沿用原本的寫法（`[a, b]` 或區塊、原本的縮排），會被讀成布林、數字、日期的文字加雙引號。沒有 frontmatter 時從文件頭的「新增屬性」建立，刪掉最後一個欄位時整個 frontmatter 一起刪除；新增 frontmatter 時游標留在它後面（不切到原始 YAML）。每次修改都是一般的 CM6 編輯（可 undo、停止輸入後照常寫回）；輸入框是 widget 內的 `<input>`，組字中不寫回，Enter 在組字中交給輸入法。游標進入 frontmatter 時顯示原始 YAML，面板暫時隱藏。
- **焦點**（`editorFocus.ts`）：表格、區塊公式、行內公式預覽只在編輯器有焦點（或搜尋列開著）且游標在範圍內時顯示原始碼。換 `EditorState`（切換筆記、換行符改變時重建）不會觸發 focus 事件，所以 `setState` 之後一律以 `view.hasFocus` 重設焦點狀態。
- **在筆記中尋找**（`search.ts`）：⌘F（Mac 的選單項目轉成 `exec("find")`，焦點在編輯器時 CM6 keymap 也會處理；表格格子裡的按鍵不經過 CM6 keymap，由格子的 keydown 處理）開啟編輯器上方的搜尋列；比對與標示用 `@codemirror/search`（純文字、預設不分大小寫），搜尋列自己做（中文介面、「第幾個 / 共幾個」，超過 1,000 個只顯示「1000+」）。Enter / ⇧Enter、⌘G / ⇧⌘G 下一個 / 上一個，Esc 關閉；只保留這些綁定，不加 ⌘D、跳到行號等。搜尋框是一般 `<input>`，組字中的 Enter 交給輸入法。搜尋列開著時焦點在搜尋框，但選到的結果若在表格、區塊公式內要看得到，所以也當作「有焦點」（`revealing`）。搜尋狀態存在 `EditorState`，切換筆記時跟著該篇。
- **合併**：diff3 三方合併。非重疊修改自動合併，重疊才產生衝突副本。編輯中收到遠端變更（同步或外部工具）時，用 `applyRemote` 套用到 CM6，保留游標與 undo。JS 端記住上次與磁碟一致的內容（`saved`）與之後還沒存檔的本地修改（`unsaved`，`ChangeSet`）；遠端變更以 `ChangeSet.map` 轉換到本地修改之上（`rebase.ts`），停止輸入 300ms 內打的字也不會被覆蓋，之後照常寫回合併後的內容。


## Bridge 協定（Swift ⇄ WebView）

| 方向 | 訊息 | 時機 |
| --- | --- | --- |
| Swift → JS | `load({id, text, meta})` | 開啟或切換筆記；`meta.modified` 給文件頭 |
| Swift → JS | `applyRemote({id, text})`、`setMeta` | 同步拉到遠端變更、寫入後更新編輯時間 |
| Swift → JS | `exec({command, arg})` | 工具列、快捷鍵（`find` 開啟搜尋列） |
| Swift → JS | `setLinkTargets(targets)` | 索引變更（自動完成、連結卡片） |
| JS → Swift | `ready` | bundle 載入完成（預熱結束） |
| JS → Swift | `changed({id, text})` | 停止輸入 300ms 或失焦 |
| JS → Swift | `openLink({target})`、`openTag({tag})` | 點擊 `[[連結]]`、`#標籤` |
| JS → Swift | `pickCover`、`pickIcon` | 文件頭的更換封面 / 圖示（原生 UI 處理，寫回 frontmatter） |

主題不經 Bridge：`ThemeCSS.stylesheet()` 由 WebEditorHost 以 user script 在頁面載入前注入，深淺色由 `prefers-color-scheme` 切換；外觀偏好（`AppTheme`：跟隨系統 / 淺色 / 深色，`@AppStorage("appTheme")`，不寫進 Vault）由 App 層以 `preferredColorScheme` 套用，並同步 `NSApp.appearance` / window 的 `overrideUserInterfaceStyle`，讓平台動態色與 WebView 的 `prefers-color-scheme` 跟著變，不經 Bridge。圖片由 `vault://<Vault 相對路徑>`（`WKURLSchemeHandler`）讀取，只允許 Vault 內路徑；`![[x.excalidraw]]` 等嵌入預覽由 `embed://<Vault 相對路徑>` 提供（Phase 4，見「擴充點」）。文件 icon 為 SF Symbol（frontmatter `icon: sf:map`）時，經 `symbol:///<名稱>` 由 Swift 畫成 PNG，CSS 當 mask 上色。

## 流暢編輯的工程手法

核心規則：**打字的熱路徑永遠不跨 Bridge**。對標 Obsidian、Typora 的手感，靠以下七項：

1. **編輯器自持狀態**：按鍵只在 JS 內處理；Swift 在停止輸入 300ms 或失焦時才收到變更，大檔案傳 diff 而非全文。
2. **單一預熱 WebView**：App 啟動即載入 bundle；切換筆記只換 `EditorState`，不重載頁面。開過的筆記保留 state（最近 20 篇，LRU；`StateCache`），切回瞬間完成且 undo 還在；超過的丟掉最久沒用的，收到記憶體警告時（iOS 的 memory warning、macOS 的 memory pressure）清掉不在畫面上的。丟掉不會遺失內容（存檔在切換前就做了），再開時以磁碟內容重建，只少了 undo 與游標。
3. **增量解析 + 視窗渲染**：Lezer 增量解析，CodeMirror 6 只渲染可見行。
4. **Live Preview**：游標所在行顯示 md 語法，其餘行用 decorations 渲染為最終樣式。
5. **原生細節**：`-apple-system` 字型、Dynamic Type、深色模式；鍵盤工具列用原生 `inputAccessoryView`；macOS 快捷鍵走原生選單再轉發；圖片由 `WKURLSchemeHandler` 從本地讀取。
6. **I/O 不擋主執行緒**：atomic write、`NSFileCoordinator` + 檔案監看處理外部修改、索引在背景更新。
7. **啟動即開上一篇**：先顯示快取內容，再載入編輯器。
