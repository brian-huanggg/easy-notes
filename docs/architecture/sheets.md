# Sheets（`.csv`、`.tsv`）

- **做**：RevoGrid 編輯（修改儲存格、增刪列欄、排序與篩選檢視）；欄寬、凍結欄等顯示設定存 `.csv.meta.json`；在 md 內 `![[x.csv]]` 嵌入表格預覽。
- **不做**：公式、多工作表、圖表。CSV 只存資料；需要試算表功能時用「用其他 App 開啟」交給 Numbers / OnlyOffice。
- **實作**：Swift 端做 RFC 4180 解析與序列化，WebView 只拿列資料。未修改的列逐位元組寫回（引號風格、換行符不變），讓 diff 與合併保持乾淨。

**設計決定**：

- **外掛**：新增 `Packages/KindSheet`，只依賴 EasyNotesCore / EasyNotesUI。`.csv` 與 `.tsv` 都支援，同一套解析器，只差分隔符（`,` / tab）。
- **表格元件：RevoGrid（內建編輯器）**：S5 Spike 在 Mac 與 iPad 實機驗證通過：選取後直接以注音打字不吃字、組字中的 Enter（`isComposing`）不結束編輯、1 萬列捲動 60 fps、bundle 約 334 KB、關閉後 WebContent process 結束。因此直接用 RevoGrid 的內建編輯器，不另做輸入層。備案：若之後在特定情境發現吃字，改在選取的儲存格位置放一個常駐焦點的隱藏 `textarea`（同 Google Sheets；Spike 已有原型，要點是延到下一幀才 `focus()`、定位用 `.rgCell[data-rgrow][data-rgcol]`），組字中的 Enter 仍以 `isComposing` 判斷。再不行才改用自寫的 TS 虛擬表格或原生表格；6a 的模型不受影響。
- **模型：保留原始位元組**：每筆記錄（record）保留原始位元組與解析後的欄位；未修改的記錄原樣寫回，修改過的記錄依檔案的風格重新產生。偵測：換行符（LF / CRLF，取多數）、引號風格（全部加 / 必要時才加）、BOM、檔尾是否有換行。欄數不一的列原樣保留，顯示時補空格，未編輯就不寫回補的空格。
- **編碼**：UTF-8（含或不含 BOM）可編輯；偵測為 Big5（台灣 Excel 匯出常見）時唯讀開啟，提供「轉成 UTF-8」。
- **索引**：標題 = 檔名；`plainText` = 儲存格內容（設上限，避免巨大檔案拖慢 FTS）；摘要「CSV · 86 列 · 5 欄」；儲存格中的 `[[連結]]` 收進 `links`，`renameLinks` 一併更新。
- **合併**：以**記錄**為單位的 diff3（帶引號的欄位可以跨行，所以不是以實體行為單位），直接用 Core 的泛型 `Diff3.merge`。兩邊改了同一筆記錄的不同儲存格時，再以儲存格為單位做三方合併；新增或刪除欄會讓每一列都變動 → 衝突副本（接受）。
- **編輯器與 Bridge**：每次開檔建立自己的 `WebEditorHost`、關閉後釋放（不與 Markdown 的預熱 WebView 共用）。`load({rows, meta})` 一次送出全部列，每列帶 Swift 給的穩定 row id（排序或篩選後仍能對回原本的列）；JS 在**儲存格編輯結束時**才送 `edit({ops})`（`setCell`、增刪列欄），不是每個按鍵，打字熱路徑不跨 Bridge。Swift 把 ops 套到模型上，延遲 300 ms 寫檔。註冊 `EditorController`：`externalChange` 重新解析後以 `applyRemote` 更新並盡量保留選取，`flush` 立即存檔。Undo 由 JS 以 op 堆疊實作。剪貼簿用 TSV，與 Numbers / Excel 互通。`addMenu("表格")` 提供插入 / 刪除列欄、凍結首欄。
- **排序與篩選只影響畫面**：不改寫檔案（整檔重新排序會讓每一列都變動，diff3 無法合併）；需要時提供明確的「依此欄排序並寫入」。
- **顯示設定 `.csv.meta.json`**（`.tsv.meta.json` 相同）：`{version, columns: [{width}], frozenColumns, headerRow}`；只在使用者改了顯示設定時才建立；增刪欄時由編輯器一起調整。以 Phase 5 的 `companionOf` 註冊為伴隨檔（列表隱藏、跟著主檔改名搬移刪除）；合併以欄位為單位 LWW。
- **預覽與嵌入**：`makePreview` 在背景用 CoreGraphics 畫前約 8 列 × 6 欄的 PNG（設計稿 Thumb CSV `otUrV`），`![[x.csv]]` 經 `embed://` 用同一張圖；深色模式同白板（透明背景、顯示端反相）。
- **新增與匯入**：`addKind`（`tablecells`、`type-csv`）、`addNewFile("新表格")`（範本只有一列標題）、`addImport("匯入 CSV…")`；`addVaultGuide` 說明 CSV 慣例（UTF-8、第一列是標題、不要手動修改 `.csv.meta.json`）。
