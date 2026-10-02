# PDF 手寫與標註

- **做**：開啟 PDF；原子筆、螢光筆、橡皮擦、套索選取、便利貼；匯出合併標註後的 PDF。
- **不做**：插入空白頁、頁面縮圖與重排、PDF 文字搜尋、手寫辨識、建立新 PDF（只能匯入）。
- **實作**：`PDFView` + `PDFPageOverlayViewProvider`，每個可見頁面疊一個 `PKCanvasView`，離開畫面就回收，避免大檔案吃光記憶體（S4 實機確認，見下方）。`drawingPolicy = .pencilOnly`，手指捲動與縮放、Pencil 書寫。
- **格式**：原始 PDF 不改動。標註存在 `<檔名>.pdf.ink`（JSON）：`pdfHash` + 依頁碼分組的 Excalidraw elements。檔案樹中隱藏 `.pdf.ink`。
- **平台**：macOS 顯示 PDF 與所有標註，便利貼可新增、移動、編輯；手寫只能看。

**設計決定**：

- **共用 `ExcalidrawKit`**：元素模型、`merge`、`InkStroke` / PencilKit 轉換、`ElementGeometry`、`TextLayout`、`ElementPainter`、`SceneRenderer` 從 KindWhiteboard 搬進共用函式庫（見 [README](./README.md)「依賴規則」），兩個外掛都依賴它。layer 樹、編輯核心、文字框等畫布元件留在 KindWhiteboard；PDF 真的需要時再個別搬。
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
- **記憶體**：記憶體中的標註是「頁碼 → elements 字典」（便宜）；`PKDrawing` 只為有 overlay 的頁面建立；每次 `canvasViewDrawingDidChange` 就把該頁筆畫換回 elements（Undo 也需要前後狀態），所以 overlay 回收時不必另外存檔，直接丟掉畫布。
- **Undo 記在模型，不靠 `PKCanvasView`**：overlay 會被回收，PencilKit 註冊在畫布上的 undo 會指向已釋放的 view。`PKCanvasView` 子類別回傳私有的 `undoManager`（吞掉 PencilKit 自己的註冊），`canvasViewDrawingDidChange` 時比對前後筆畫，以「頁碼 + 前後 elements」註冊到視窗的 undoManager；復原時改模型，頁面在畫面上才同步給畫布。跨頁依時間順序復原；`version` 一律遞增（同白板）。S4 實機確認可行。
- **Spike S4（iPad Air M1 實機，2026-10-03）確認可行**，實作規則：
  - `pageOverlayViewProvider` 必須在指定 `document` 之前設定；`isInMarkupMode = true`。overlay 內的 `PKCanvasView` 關閉自己的捲動（`isScrollEnabled = false`），手指拖曳才會交給 PDFView。
  - 頁面座標 ⇄ overlay 座標：overlay 是已旋轉、已縮放的頁面，換算 = 依 `rotation` 旋轉未旋轉的 cropBox 座標，再縮放到 overlay 大小；overlay 尺寸改變時重新換算。旋轉 90 / 180 / 270 的頁面對齊正確。
  - `PKToolPicker` 綁在常駐 first responder 的容器 view（`setVisible(_:forFirstResponder:)`），各頁畫布只 `addObserver`：工具選擇器不會因畫布回收而消失，各頁工具一致。容器的 `undoManager` 就是模型 Undo，系統 ⌘Z / 三指撥動直接找到它。
  - PencilKit 會在 delegate 之後才註冊 undo：在下一輪 run loop 清掉畫布私有 `undoManager` 的紀錄。
  - **清晰度**：overlay 在 PDFView 的縮放 transform 裡，PencilKit 預設以螢幕倍率點陣化，放大會糊。縮放停止 0.25 秒後把畫布（含內部子 view）的 `contentScaleFactor` 設為「螢幕倍率 × overlay 在視窗上的實際倍率」，**不設上限**（上限螢幕 × 4 時，4–5× 縮放就變糊，因為倍率包含 PDFView 開啟時的 fit 縮放）。
  - 數據：60 FPS（60Hz 上限）、最長一幀 16.7 ms；200 頁、每頁 30 筆、自動捲動（約 6,000 pt/s）時記憶體穩定在 280–300 MB，不隨捲動成長。
- **存檔與外部變動**：停止操作 500 ms 後寫入旁檔；註冊 `EditorController`，`externalChange`（同步拉下來的旁檔）以元素合併併進記憶體並更新可見頁面，`flush` 立即存檔。
- **合併**：`.pdf` 是不透明檔案（內容不同 → 衝突副本）。`.pdf.ink` 依頁合併，每頁用白板的元素合併（`id` + `version`）；`pdfHash` 不同時保留本機的。
- **PDF 被換掉**（`pdfHash` 不符）：仍依頁碼顯示標註，頂端提示「PDF 已變更，標註可能錯位」，按「保留標註」才更新 `pdfHash`。
- **伴隨檔案（Core 擴充點，不認識類型）**：`DocumentKind.companionOf`（預設 nil），`.pdf.ink` 回傳「去掉 `.ink` 的路徑」。Core 據此：檔案樹、文件列表、搜尋不顯示伴隨檔；App 內改名、搬移、刪除、還原主檔時伴隨檔一起處理；仍照常索引 hash、同步與合併。外部工具改名 PDF 時，VaultWatcher 推斷出主檔改名就一併搬移旁檔；推斷不到時，開啟沒有旁檔的 PDF 會以 `pdfHash` 找主檔不存在的孤兒旁檔認領。
- **索引與預覽**：`PDFKind.index` 只有標題與摘要（「N 頁」）；便利貼文字暫不索引。列表縮圖 = 第 1 頁（不含標註，依 PDF hash 快取；旁檔變動不會讓縮圖失效）。
- **匯入**：`addImport("匯入 PDF…")` 複製到目前資料夾；Vault 裡既有的 PDF（例如 `附件/`）因為註冊了 `.pdf` 也會出現在列表。
- **匯出：全部壓平**：用 `CGPDFContext` 逐頁畫原頁面（`PDFPage.draw(with: .cropBox, to:)`），再套用頁面旋轉、以 `SceneRenderer` 用向量畫上筆畫與便利貼；螢光筆的透明度由 CG alpha 保留。產出新檔（分享，或存成 Vault 內的 `<檔名>（標註）.pdf`），原始 PDF 不動。匯出後在其他 App 不能再編輯標註，換來任何閱讀器與列印都一致。
