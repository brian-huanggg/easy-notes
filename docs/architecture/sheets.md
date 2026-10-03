# Sheets（`.csv`、`.tsv`）

- **做**：RevoGrid 編輯（修改儲存格、增刪列欄、排序與篩選檢視）；欄寬、凍結欄等顯示設定存 `.csv.meta.json`；在 md 內 `![[x.csv]]` 嵌入表格預覽。
- **不做**：公式、多工作表、圖表。CSV 只存資料；需要試算表功能時用「用其他 App 開啟」交給 Numbers / OnlyOffice。
- **實作**：Swift 端做 RFC 4180 解析與序列化，WebView 只拿列資料。未修改的列逐位元組寫回（引號風格、換行符不變），讓 diff 與合併保持乾淨。

**設計決定**：

- **外掛**：新增 `Packages/KindSheet`，只依賴 EasyNotesCore / EasyNotesUI。`.csv` 與 `.tsv` 都支援，同一套解析器，只差分隔符（`,` / tab）。
- **表格元件：RevoGrid（內建編輯器）**：S5 Spike 在 Mac 與 iPad 實機驗證通過：選取後直接以注音打字不吃字、組字中的 Enter（`isComposing`）不結束編輯、1 萬列捲動 60 fps、bundle 約 334 KB、關閉後 WebContent process 結束。因此直接用 RevoGrid 的內建編輯器，不另做輸入層。備案：若之後在特定情境發現吃字，改在選取的儲存格位置放一個常駐焦點的隱藏 `textarea`（同 Google Sheets；Spike 已有原型，要點是延到下一幀才 `focus()`、定位用 `.rgCell[data-rgrow][data-rgcol]`），組字中的 Enter 仍以 `isComposing` 判斷。再不行才改用自寫的 TS 虛擬表格或原生表格；6a 的模型不受影響。
- **模型（`SheetDocument`）**：每筆記錄有穩定的 row id（開檔時依序給，之後新增的列接續編號，不寫進檔案）、欄位與原始位元組；行尾（`\n` / `\r\n` / 檔尾沒有換行時為空）另外存，不屬於記錄本身。編輯 API 對應 Bridge 的 ops：`setCell`、`insertRows`、`deleteRows`、`insertColumn`、`deleteColumn`；新列補滿目前欄數，新增欄不影響空白行。
- **模型：保留原始位元組**：每筆記錄（record）保留原始位元組與解析後的欄位；未修改的記錄原樣寫回，修改過的記錄依檔案的風格重新產生。偵測：換行符（LF / CRLF，取多數）、引號風格（全部加 / 必要時才加）、BOM、檔尾是否有換行。欄數不一的列原樣保留，顯示時補空格，未編輯就不寫回補的空格。
- **編碼**：UTF-8（含或不含 BOM）可編輯；偵測為 Big5（台灣 Excel 匯出常見，以 CP950 解碼）時唯讀開啟，提供「轉成 UTF-8」；兩者都不是時以 UTF-8 容錯顯示、唯讀。分隔符、引號、換行都是 ASCII，Big5 的第二個位元組不會落在這些值，所以解析一律在位元組上做，再逐欄位解碼。唯讀的檔案不做 `renameLinks`、合併只接受兩邊相同。
- **索引**：標題 = 檔名；`plainText` = 儲存格內容（設上限，避免巨大檔案拖慢 FTS）；摘要「CSV · 86 列 · 5 欄」；儲存格中的 `[[連結]]` 收進 `links`，`renameLinks` 一併更新。
- **合併**：以**記錄**為單位的 diff3（帶引號的欄位可以跨行，所以不是以實體行為單位），直接用 Core 的泛型 `Diff3.merge`，衝突區塊交給它的 `resolve`：兩邊改了同一筆記錄（或相鄰記錄）的不同儲存格時，逐記錄、再逐儲存格做三方合併；兩邊在同一位置各自新增列（最常見：都附加在檔尾）時兩邊都保留，本地在前；同一儲存格兩邊改成不同值、一邊刪列一邊改列、欄數不同 → 衝突副本。合併前把檔尾沒有換行的最後一筆補上換行再比，結果依本地的風格（BOM、檔尾換行）還原。新增或刪除欄會讓每一列都變動 → 衝突副本（接受）。
- **編輯器與 Bridge**：每次開檔建立自己的 `WebEditorHost`（`SheetSession`，由 `SheetController` 登記）、關閉後先寫檔再釋放（不與 Markdown 的預熱 WebView 共用）。`sheet.load(json)` 一次送出全部列（JSON 字串，JS 端 `JSON.parse`；1 萬列在 Chromium 約 0.1 秒），每列帶 Swift 給的穩定 row id（排序或篩選後仍能對回原本的列）；JS 在**儲存格編輯結束時**才送 `edit`（ops 的 JSON 字串：`set`、`insertRows`、`deleteRows`、`insertColumn`、`deleteColumn`、`order`），不是每個按鍵，打字熱路徑不跨 Bridge。JS 新增的列自己配負數 id，Undo 不必等 Swift 回覆，也不會與 Swift 配的 id 衝突。Swift 把 ops 套到模型上，停止編輯 300 ms 後寫檔；套用失敗（模型與畫面對不上）就以模型為準重新 `load`。註冊 `EditorController`：`externalChange` 先把未寫出的編輯與外部內容三方合併（合併不了以外部為準），`replaceContent` 讓沒變的列沿用 id，再以 `applyRemote` 更新畫面並保留選取；儲存格編輯器開著時延到編輯結束才套用（否則關閉編輯器會把舊值寫回）。`flush` 結束編輯中的儲存格並立即存檔。Undo 由 JS 以 op 堆疊實作（復原也是一般的 `edit`），⌘Z / ⌘⇧Z 在 JS 處理、編輯儲存格時交給輸入框。剪貼簿用 RevoGrid 內建的 TSV，與 Numbers / Excel 互通。`addMenu("表格")` 提供插入 / 刪除列欄、依此欄排序並寫入、凍結首欄、第一列是標題。
- **標題列**：預設檔案第一列固定在上方（RevoGrid 的 `pinnedTopSource`）、加粗，不參與排序與篩選（含「依此欄排序並寫入」）；欄名用 A、B、C…。「第一列是標題」（顯示設定 `headerRow`）關掉時第一列是一般資料列。限制：固定列不支援「選取後直接打字」，要按 Enter 或雙擊才進入編輯。
- **排序與篩選只影響畫面**：不改寫檔案（整檔重新排序會讓每一列都變動，diff3 無法合併）；需要時提供明確的「依此欄排序並寫入」。
- **顯示設定 `.csv.meta.json`**（`.tsv.meta.json` 相同，`SheetMeta`）：`{version, columns: [{width}], frozenColumns, headerRow}`。`columns` 依欄位順序、`width` 缺少 = 預設寬度（140），比欄數少時其餘欄位是預設值，結尾的預設欄位不寫；缺少的欄位都用預設值（`frozenColumns` 0、`headerRow` true），手動編輯或舊版的旁檔也能讀。
  - **誰改、誰寫**：顯示設定由 JS 改（拖曳欄寬、「凍結首欄」、「第一列是標題」），改了才把整份以 `meta` 訊息（JSON 字串）送給 Swift，與 `edit` 同一個 300 ms 延遲寫檔；`load` 時 Swift 一併送出。旁檔只在設定不是預設值時建立，已經存在就照常更新（改回預設值也寫，不刪檔）。
  - **增刪欄**：JS 套用 `insertColumn` / `deleteColumn` 時一起移動 `columns`（插入的欄是預設寬度），插在 / 刪在凍結範圍內時 `frozenColumns` 加減一，再送 `meta`；Undo 刪欄時欄寬回到預設值。外部工具增刪欄不會調整旁檔（欄寬可能對到別欄，接受）。
  - **伴隨檔**：`CSVMetaKind` / `TSVMetaKind` 以 `addCompanionKind` 註冊，`companionOf` 去掉 `.meta.json`（Phase 5 的機制：列表隱藏、照常索引與同步、跟著主檔改名搬移刪除）。開啟中表格的旁檔被外部修改或同步改寫時，`SheetController.externalChange` 收到旁檔路徑，合併後以 `applyMeta` 更新畫面。
  - **合併**：以欄位為單位的三方合併（`frozenColumns`、`headerRow`、每一欄的 `width` 各自比）：只有一邊改的用那一邊，兩邊都改成不同值時本地優先；沒有共同基準時以預設值為基準。不需要時間戳記，顯示設定被蓋掉的代價很小。一邊不是合法 JSON 就用另一邊，兩邊都不合法才交給衝突副本。
- **預覽與嵌入（`SheetPreview`）**：CSV、TSV 各註冊一個（帶分隔符）。`makePreview` 在背景用 CoreGraphics + CoreText 畫前 8 列 × 6 欄的 PNG，版面同設計稿 `C/Thumb CSV`（`otUrV`）：標題列 22 pt（`type-csv-soft` 底、`type-csv` 粗體字）、資料列 18 pt、字級 8.5、欄之間與列底下的格線、沒有外框；欄寬依內容，限制在 44–120 pt，超出的文字以「…」截斷，多行的儲存格只畫第一行；2 倍像素。背景透明、淺色配色，深色模式在顯示端反相（同白板：卡片用 `colorInvert` + `hueRotation`，md 嵌入用 CSS `invert(93%) hue-rotate(180deg)`）。第一列一律畫成標題列：預覽依主檔內容 hash 快取，不讀顯示設定旁檔。卡片上表格以原本大小（乘上卡片倍率）靠左上擺放、超出的部分裁掉；`lines` 是第一列的前 4 格，沒有圖（空檔案）時以 `ThumbTable` 骨架顯示。`![[x.csv]]` 經 `embed://` 用同一張圖，Markdown 外掛不需要知道表格。
- **新增與匯入**：`addKind`（`tablecells`、`type-csv`）、`addNewFile("新表格")`（CSV；範本只有一列標題「名稱,備註」，沒有快捷鍵）、`addImport("匯入 CSV…")`（只選 `.csv`；TSV 由 Finder 或其他工具放進 Vault）；`addVaultGuide` 以英文說明表格慣例（UTF-8、第一列是標題、引號規則、保留原本的風格只改需要的列、不要修改 `.csv.meta.json`、Big5 唯讀）。
