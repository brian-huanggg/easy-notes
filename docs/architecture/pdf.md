# PDF 手寫與標註

- **做**：開啟 PDF；原子筆、螢光筆、橡皮擦、套索選取、便利貼；匯出合併標註後的 PDF。
- **不做**：插入空白頁、頁面縮圖與重排、PDF 文字搜尋、手寫辨識、建立新 PDF（只能匯入）。
- **實作**：`PDFView` + `PDFPageOverlayViewProvider`，每個可見頁面疊一個 `PKCanvasView`，離開畫面就回收，避免大檔案吃光記憶體（S4 實機確認，見下方）。`drawingPolicy = .pencilOnly`，手指捲動與縮放、Pencil 書寫。
- **格式**：原始 PDF 不改動。標註存在 `<檔名>.pdf.ink`（JSON）：`pdfHash` + 依頁碼分組的 Excalidraw elements。檔案樹中隱藏 `.pdf.ink`。
- **平台**：macOS 顯示 PDF 與所有標註，便利貼可新增、移動、縮放、編輯；手寫只能看。

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
- **macOS 便利貼**：右下角「便利貼」按鈕在目前頁可見範圍的中央新增一張並直接編輯。overlay 只在滑鼠落在便利貼上時接收事件，其餘交給 PDFView（選取文字、捲動）。滑鼠移到便利貼上時顯示外框與右下角的縮放點。拖曳移動、拖曳縮放點縮放（最小 40 頁面點，文字依新尺寸重新排版）：拖曳中標註層只重畫這張的範圍把它隱藏，改由同步繪製的預覽 view（`NSView.draw`，不是分塊的 `CATiledLayer`：分塊是非同步畫的，移動到新位置時還沒畫好的塊會讓便利貼缺一角、露出底下的 PDF 文字）跟著游標，放開才寫入一次。雙擊或右鍵「編輯」疊一個 `NSTextView`（便利貼底色、字級隨縮放），結束編輯（點別處、Esc、切換檔案前的 `flush`）才寫回文字並重新排版，所以注音組字中不寫回；右鍵「刪除」。旋轉頁上的編輯框不跟著旋轉（顯示時文字仍隨頁面旋轉）。
- **頁面疊層**：overlay view = 便利貼 layer（`ElementPainter`）+ `PKCanvasView`。手寫模式開關與白板相同（畫筆 = 開關，開啟時顯示 `PKToolPicker`：鋼筆、螢光筆、橡皮擦、套索）；手寫模式中手指捲動縮放、長按便利貼才拖曳；關閉時 Pencil 與手指都能點選、拖曳便利貼。iPad `.pencilOnly`，iPhone 只在手寫模式用手指書寫。所有頁面共用一個 `PKToolPicker`。
- **標註層（兩個平台共用）**：每頁 overlay 的底層是一個 `CATiledLayer`，以 `SceneRenderer`（內部用 `ElementPainter`）在背景執行緒分塊畫出該頁的便利貼與筆畫：放大時依倍率重畫區塊，所以清晰，而且只畫看得到的部分；整頁點陣在 5× 縮放會到數百 MB，不可行。唯讀檢視（Mac、iPad 非手寫模式）只有這一層；iPad 5c 在上面疊 `PKCanvasView`，此時標註層不畫 freedraw（`drawsFreedraw: false`）。標註改變時只重畫有 overlay 的頁。
- **開啟流程**：`PDFDocument(url:)` 延遲讀取頁面；`pdfHash` 在背景計算（大檔不擋主執行緒），沒有旁檔時同一個背景工作執行 `claimOrphan`，認領後以 `DocumentSession.fileMoved` 通知同步層。旁檔在第一次寫入標註時才建立，並寫入當時的 `pdfHash`。
- **記憶體**：記憶體中的標註是「頁碼 → elements 字典」（便宜）；`PKDrawing` 只為有 overlay 的頁面建立；每次 `canvasViewDrawingDidChange` 就把該頁筆畫換回 elements（Undo 也需要前後狀態），所以 overlay 回收時不必另外存檔，直接丟掉畫布。
- **Undo 記在模型，不靠 `PKCanvasView`**：overlay 會被回收，PencilKit 註冊在畫布上的 undo 會指向已釋放的 view。`PKCanvasView` 子類別回傳私有的 `undoManager`（吞掉 PencilKit 自己的註冊），`canvasViewDrawingDidChange` 時比對前後筆畫，以「頁碼 + 前後 elements」註冊到視窗的 undoManager；復原時改模型，頁面在畫面上才同步給畫布。跨頁依時間順序復原；`version` 一律遞增（同白板）。S4 實機確認可行。
- **Spike S4（iPad Air M1 實機，2026-10-03）確認可行**，實作規則：
  - `pageOverlayViewProvider` 必須在指定 `document` 之前設定；`isInMarkupMode = true`。overlay 內的 `PKCanvasView` 關閉自己的捲動（`isScrollEnabled = false`），手指拖曳才會交給 PDFView。
  - 頁面座標 ⇄ overlay 座標：不假設 overlay 的版面，一律以 PDFKit 換算（頁面上原點、右上、左下三點經 `PDFView.convert(_:from: page)` 再轉到 overlay，求出仿射變換），overlay 尺寸改變時重新換算。原因：iOS 非手寫模式下，旋轉頁的 overlay 是**未旋轉**的 bounds 加上旋轉 `transform`（S4 原型在手寫模式中自己套 `rotation` 卻對齊，推測版面依 `isInMarkupMode` 而不同），自己套 `rotation` 會轉兩次。旋轉 90 / 180 / 270 的頁面對齊正確。
  - `PKToolPicker` 綁在常駐 first responder 的容器 view（`setVisible(_:forFirstResponder:)`），各頁畫布只 `addObserver`：工具選擇器不會因畫布回收而消失，各頁工具一致。容器的 `undoManager` 就是模型 Undo，系統 ⌘Z / 三指撥動直接找到它。
  - PencilKit 會在 delegate 之後才註冊 undo：在下一輪 run loop 清掉畫布私有 `undoManager` 的紀錄。
  - **清晰度**：overlay 在 PDFView 的縮放 transform 裡，PencilKit 預設以螢幕倍率點陣化，放大會糊。縮放停止 0.25 秒後把畫布（含內部子 view）的 `contentScaleFactor` 設為「螢幕倍率 × overlay 在視窗上的實際倍率」，**不設上限**（上限螢幕 × 4 時，4–5× 縮放就變糊，因為倍率包含 PDFView 開啟時的 fit 縮放）。
  - 數據：60 FPS（60Hz 上限）、最長一幀 16.7 ms；200 頁、每頁 30 筆、自動捲動（約 6,000 pt/s）時記憶體穩定在 280–300 MB，不隨捲動成長。
- **存檔與外部變動**：停止操作 500 ms 後寫入旁檔；註冊 `EditorController`，`externalChange`（同步拉下來的旁檔）以元素合併併進記憶體並更新可見頁面，`flush` 立即存檔。
- **合併**：`.pdf` 是不透明檔案（內容不同 → 衝突副本）。`.pdf.ink` 依頁合併，每頁用白板的元素合併（`id` + `version`）；`pdfHash` 不同時保留本機的。
- **PDF 被換掉**（`pdfHash` 不符）：仍依頁碼顯示標註，頂端提示「PDF 已變更，標註可能錯位」，按「保留標註」才更新 `pdfHash`。
- **伴隨檔案（Core 擴充點，不認識類型）**：`DocumentKind.companionOf`（預設 nil），`.pdf.ink` 回傳「去掉 `.ink` 的路徑」；伴隨檔路徑必須以主檔路徑開頭，改名時 Core 只換掉主檔路徑、後綴不變。`PDFKind` 以 `addKind` 註冊，`PDFInkKind` 以 `addCompanionKind` 註冊（進 KindRegistry，但不是篩選 chip）。Core 據此：
  - 檔案樹、文件列表、搜尋、`[[連結]]` 解析、「最近刪除」不顯示伴隨檔；仍照常索引 hash、同步與合併。
  - App 內改名、搬移（`VaultFS.rename`）、刪除（`VaultFS.trash`）主檔時伴隨檔一起處理，並通知同步層與編輯器；從「最近刪除」還原主檔時，同路徑最近刪除的伴隨檔一起還原到主檔旁。
  - 開啟中檔案的伴隨檔被外部修改或同步改寫時，`externalChange` 帶伴隨檔的路徑送給編輯器（PDF 編輯器合併旁檔）。
  - 外部工具改名 PDF：同步層的掃描推斷出主檔改名（hash 相同）時，把留在原地的旁檔搬到新名字旁並保留 file id。推斷不到（例如未登入同步）時，開啟沒有旁檔的 PDF 以 `PDFInk.claimOrphan` 找主檔不存在、`pdfHash` 相同的孤兒旁檔認領（同資料夾優先），搬移後由呼叫端通知同步層。
- **程式結構**：`KindPDF/Model/`：`PDFInk`（旁檔讀寫、依頁合併；`scene(page:)` 把一頁當成 `ExcalidrawScene`，筆畫轉換、渲染、便利貼都沿用 `ExcalidrawKit`）、`PDFPageGeometry`（未旋轉頁面座標 ⇄ 顯示座標、`displayTransform`、PDF 使用者空間）。`pdfHash` 與同步層的內容 hash 同格式（SHA-256 小寫 hex）。
- **索引與預覽**：`PDFKind.index` 只有標題與摘要（「N 頁」）；便利貼文字暫不索引。列表縮圖 = 第 1 頁（不含標註，依 PDF hash 快取；旁檔變動不會讓縮圖失效）：背景以 CoreGraphics 的 `CGPDFPage` 畫成白底 PNG（最長邊 800 px，套用頁面 `rotation`），深色模式不反相（紙張保持白色）；卡片上是灰底中的一張紙，左上類型標記、右上頁數，與設計稿 `C/Thumb PDF` 相同。
- **匯入**：`addImport("匯入 PDF…")` 複製到目前資料夾；Vault 裡既有的 PDF（例如 `附件/`）因為註冊了 `.pdf` 也會出現在列表。
- **匯出：全部壓平**：用 `CGPDFContext` 逐頁畫原頁面（`PDFPage.draw(with: .cropBox, to:)`），再套用頁面旋轉、以 `SceneRenderer` 用向量畫上筆畫與便利貼；螢光筆的透明度由 CG alpha 保留。產出新檔（分享，或存成 Vault 內的 `<檔名>（標註）.pdf`），原始 PDF 不動。匯出後在其他 App 不能再編輯標註，換來任何閱讀器與列印都一致。

## Spike (S4) 測試結果

2026-10-03：原型完成（新外掛 `KindPDF`，目前只有 `Spike/PDFOverlaySpike.swift`），iOS Simulator 與 macOS 建置成功，尚未在 iPad 實機量測。用法：

- 側邊欄「PDF Spike」面板只在 DEBUG 或啟動參數 `-PDFSpike YES` 時出現（Release 量測同 S3）。不讀寫 Vault；預設載入程式產生的 200 頁範例，「選項 → 開啟 PDF…」可換成真實講義。
- 範例：每 10 頁有一頁橫向（第 4、14…頁），第 6 / 8 / 10…頁設 `rotation` 90 / 180 / 270。每頁印藍色參考框（內縮 36 pt）與左上 L 記號；「加入對齊參考筆畫」從模型（未旋轉頁面座標）畫紅線，正確時紅線完全疊在藍線上，縮放、旋轉頁都應如此。
- 做法：模型是「頁碼 → `PKDrawing`（未旋轉頁面座標）」，overlay 只是暫時檢視，每次畫完立刻換算寫回模型；`PKToolPicker` 綁在常駐 first responder 的容器 view，各頁畫布只當 observer；畫布子類別回傳私有 `undoManager`，模型 Undo 註冊在容器（工具列按鈕、⌘Z、三指撥動）。
- HUD：FPS / 最長一幀、記憶體（phys_footprint）與峰值、目前頁 / overlay 數（累計建立數）/ 有筆畫頁數、縮放與畫布點陣倍率、overlay 重新換算次數、目前頁 overlay 尺寸 / cropBox / 旋轉、Undo 狀態、最近復原的頁、PencilKit undo 被吞的次數。
- 選項：自動捲動（約 6,000 pt/s 來回，壓力測試）、縮放後重設 `contentScaleFactor`、模型 Undo（關閉 = PencilKit 原生，用來對照回收後的 undo）、手指也能書寫（Simulator）、每頁加 30 筆隨機筆畫、清除、重設記憶體峰值。

實機待確認：(1) 4× 時筆畫是否清晰，重設 `contentScaleFactor` 有沒有效（overlay 尺寸若跟著縮放變，「重新載入」會一直增加）；(2) 旋轉頁紅藍線是否重疊；(3) 手指捲動不畫、Pencil 書寫；(4) 換頁畫時工具選擇器不消失、選的工具各頁一致；(5) 第 1 頁畫 → 捲到第 150 頁畫 → 連按 ⌘Z 依序復原兩頁，「PencilKit 被吞」> 0；(6) 每頁加隨機筆畫後自動捲動一分鐘，overlay 數與記憶體不持續成長。

### 2026-10-03 第一輪實機結果（iPad Air M1，60Hz）：

| 項目 | 結果 |
| --- | --- |
| 幀率 | 60 FPS，最長一幀 16.7 ms（= 該機型上限） |
| 跨頁 Undo / Redo | 正常 |
| 旋轉頁對齊 | 正常（紅藍線重疊） |
| 記憶體 | 100–200 MB |
| 4–5× 縮放 | Pencil 筆畫解析度下降 |

第一輪後的修改（待第二輪驗證）：

- 解析度：推測是點陣倍率上限。原型把畫布 `contentScaleFactor` 限制在「螢幕倍率 × 4」，但倍率是依 overlay 在螢幕上的實際大小算（包含 PDFView 開啟時的 fit 縮放），4–5× 縮放時超過上限。選項新增「點陣上限」（螢幕 × 4 / 6 / 8 / 不限，預設不限）；HUD 新增「螢幕上」倍率（overlay 1 pt 在視窗上的大小），raster 應等於它 × 螢幕倍率。
- 第二輪要量：預設「不限」時 4–5× 是否清晰、記憶體峰值多少；與「螢幕 × 4」對照。若不限就清晰但記憶體過高，再考慮只對畫面內的區域提高點陣（或縮放到某倍率以上改用單一 `PKCanvasView` 疊在 PDFView 之上）。

### 2026-10-03 第二輪實機結果：

| 項目 | 結果 |
| --- | --- |
| 共用 `PKToolPicker` | 換頁書寫時工具選擇器不消失，各頁工具一致 |
| 吞掉 PencilKit 的 undo | 「PencilKit 被吞」> 0，跨頁 Undo 正常（第一輪） |
| 200 頁 + 每頁 30 筆、自動捲動 | 記憶體 280–300 MB，持續捲動不成長 |
| 4–5× 清晰度（點陣上限「不限」） | 清晰 |

S4 通過：疊層架構不需修改，結論與實作規則寫入 [pdf.md](./architecture/pdf.md)。正式版（5c）點陣倍率不設上限。
