# Whiteboard（`.excalidraw`）

- **做**：無限畫布；手寫層（筆、橡皮擦、套索）；結構層 6 種元素：rectangle、ellipse、arrow（可綁定到形狀）、text、image、frame；選取、移動、縮放。
- **不做**：Excalidraw Web runtime；手寫辨識與搜尋索引（手寫多為 brainstorming，不是主要筆記）；即時協作。
- **實作**：`PKCanvasView` 處理手寫，存成 freedraw 元素（已有 `ExcalidrawInk` 轉換）。結構元素由 UIKit / AppKit view 繪製（見下方），序列化成標準 Excalidraw elements。未知元素與欄位原樣寫回，檔案可在 excalidraw.com 開啟。
- **平台**：`PKCanvasView` 只有 iOS/iPadOS，macOS 上手寫只能顯示，結構元素可編輯。

**設計決定**：

- **維持原生，不用 Excalidraw Web runtime**：Excalidraw 每一筆都送出整個場景，放在 WebView 會讓 Pencil 輸入跨 Bridge；Pencil 延遲、bundle 大小與多一個 WebContent process 也都不划算。需要 Excalidraw 的進階功能時用「用其他 App 開啟」或 excalidraw.com。
- **結構層用 layer，不用 SwiftUI Canvas**：每個元素一個 `CAShapeLayer` / `CATextLayer`（只建立畫面內的元素），平移與縮放交給 Core Animation；SwiftUI Canvas 在縮放時每一幀整個重畫，1,000 個元素做不到流暢。結構層放在 `PKCanvasView` 底下，跟著它的 `contentOffset` / `zoomScale` 移動；縮放結束時重設 `contentsScale` 讓線條清晰。Spike S3（iPad Air M1 實機）確認可行，實作規則：
  - 結構層的 transform 在 `scrollViewDidScroll` / `DidZoom` 中同步設定（螢幕座標 = 畫布座標 × zoom − contentOffset），與 PencilKit 在同一個 CATransaction 提交，不會落後一幀。
  - **關閉縮放回彈**（`bouncesZoom = false`）：回彈是 Core Animation 動畫，期間 scroll view 不會每幀回呼，結構層直接跳到終點、筆畫還在動畫中，兩者會對不上。
  - **點陣倍率跟著縮放**（0.25…4）：縮放中不重新點陣化既有的 layer，新建的 layer 用目前倍率；縮放結束後分批重新點陣化。建立 layer 與重新點陣化每幀最多約 120 個，剩下的交給之後的幀。
  - **文字 layer 關閉 `contents` 動作**：文字是點陣 `contents`，預設換內容時淡入淡出 0.25 秒，舊點陣以新倍率顯示會成為放大 / 縮小的殘影。改 `contentsScale` 後在同一個 transaction 內 `displayIfNeeded()`。`CAShapeLayer` 是向量，沒有這個問題。
  - 1,000 個元素在 60Hz 機型維持 60 FPS；10,000 個元素降到約 30 FPS（縮小時全部在畫面內），需要 LOD（縮放倍率低時改畫點陣快照）。
- **疊放順序**：編輯器中手寫一律在結構元素之上（`PKCanvasView` 是獨立的一層，無法插在圖形之間）。存檔時保留檔案中的元素順序；縮圖、嵌入與 Mac 檢視依檔案順序繪製。
- **元素範圍**：可**顯示**所有標準類型（rectangle、diamond、ellipse、line、arrow、text、freedraw、image、frame，含 `angle` 旋轉、曲線與 elbow 箭頭）；可**建立**的是 rectangle、ellipse、arrow（直線，可綁定）、text、image、frame。`embeddable`、`iframe` 等顯示為帶標題的佔位框，原樣保留。不模擬 rough.js 的手繪風格：`roughness`、`fillStyle`、`fontFamily` 原樣保留，顯示時用乾淨線條與系統字型；新元素 `roughness: 0`。
- **元素順序與 fractional index**：新版 Excalidraw 的元素有 `index`（fractional index）。有 `index` 時依它排序，新元素產生合法的 index（插在兩者之間）；合併後依 `index` 排序，沒有 `index` 的舊檔案沿用陣列順序。演算法照 rocicorp/fractional-indexing（Excalidraw 用的同一套，base62）。所有元素都有合法 index 才算「有 index 的場景」；舊檔案不補 index（補了每個元素都要遞增 version），新元素也不加。index 相同（兩台裝置在同一處插入）時以 id 排序，兩邊合併結果一致。
- **箭頭綁定**：箭頭的 `startBinding` / `endBinding`（`elementId`、`focus`、`gap`，新版另有 `fixedPoint`）與形狀的 `boundElements` 兩邊一起維護。形狀移動或縮放後重算綁定箭頭的端點；只修改需要變的欄位並遞增 `version`。以 excalidraw.com 匯出的檔案當 fixture。端點 = 從相鄰點朝錨點（`fixedPoint` 在形狀上的位置，沒有時用中心）的射線，與「形狀輪廓向外擴 `gap`」的交點，所以端點到輪廓的距離就是 `gap`；形狀可旋轉，矩形、橢圓、菱形各自算輪廓。`focus` 只為舊版 Excalidraw 近似計算，以 `fixedPoint` 為準。elbow 箭頭的端點暫不重算（需要重新走線）。刪除形狀 → 箭頭的該端綁定清除；刪除箭頭 → 從形狀的 `boundElements` 移除；箭頭單獨移動而形狀沒動 → 解除該端綁定。
- **文字**：`containerId` 綁在形狀內的文字隨形狀移動、在形狀內置中換行。編輯時在元素上疊原生 `UITextView` / `NSTextView`（注音組字是原生的），結束編輯才寫回元素。
- **圖片**：標準格式 `files[fileId].dataURL`（base64 內嵌，excalidraw.com 才打得開）。插入時用 ImageIO 縮到最長邊 2048px 並轉 JPEG（有透明度的圖保留 PNG），避免 JSON 暴增；`fileId` 由內容 hash 決定，同一張圖只內嵌一次；刪除元素不刪 `files`（與 Excalidraw 相同）。顯示依尺寸產生縮圖，不解碼原圖。
- **frame**：子元素以 `frameId` 指向 frame；移動 frame 時子元素一起移動，frame 內容依 frame 範圍裁切。
- **修改即遞增 version**：任何元素改動都遞增 `version`、重抽 `versionNonce`、更新 `updated`，元素層級合併（`ExcalidrawScene.merge`）依賴它們。
- **手勢分工**：筆模式下 Pencil 書寫、手指捲動與縮放（iPad 固定 `drawingPolicy = .pencilOnly`，不跟隨系統「僅使用 Apple Pencil 繪圖」設定；iPhone 通常沒有 Pencil，手指也能書寫）；手指點一下選取（空白處取消），長按約 0.35 秒才拖曳圖形，避免捲動時誤抓。選取模式停用 PencilKit 的手勢，手指與 Pencil 碰到圖形就拖曳。
- **Undo**：結構操作註冊在 `PKCanvasView` 的 `undoManager`，與筆畫依時間順序共用一個堆疊（⌘Z、三指手勢都適用）。
- **開啟中的白板接收外部變動**：Whiteboard 註冊 `EditorController`：`externalChange` 把磁碟內容以 `ExcalidrawScene.merge` 併進記憶體中的場景並更新畫面；`flush` 立即存檔。否則開著白板時同步或 Claude Code 寫入的元素會被舊場景覆蓋。
- **連結**：元素的 `link` 若是 `[[筆記]]`，`index()` 收進 `links`（白板出現在反向連結）；`renameLinks` 更新 `link` 與 `customData.easynotes.file`。
- **渲染器共用**：`SceneRenderer`（CoreGraphics，可在背景執行緒）同時用於列表縮圖、`![[x.excalidraw]]` 嵌入與 Mac 檢視；編輯器的 layer 樹沿用同一套幾何（路徑、文字排版）。幾何集中在 `ElementGeometry`（輪廓、線與曲線、箭頭頭部、旋轉、畫面範圍），`SceneRenderer` 與 layer 樹都從它取 `CGPath`；`SceneRenderer.draw(in:visible:)` 只畫與可見範圍相交的元素，Mac 檢視直接用它。
- **渲染數值**：照 Excalidraw：圓角（`roundness.type` 3 固定 32、小形狀 25%；其他 25%）、箭頭頭部大小與角度、虛線 `[8, 8+w]`、點線 `[1.5, 6+w]`、首尾距離 ≤ 8 的 line 可填色。`fillStyle` 一律畫實心；frame 外框與標題用固定樣式（`#bbb` / `#999`），不看 `strokeColor`；`magicframe` 等未知類型畫佔位框。
- **手寫寬度**：EasyNotes（PencilKit）筆畫用 `customData` 的點大小；excalidraw.com 的筆畫照 perfect-freehand（strokeWidth × 4.25、thinning 0.6）。半透明元素整個合成後才套用透明度。
- **文字與圖片**：文字直接用檔案中已換行的 `text`（Excalidraw 存檔時就換好行），不重新排版，避免字型寬度不同時換行與網頁不一樣。圖片依顯示像素解碼（2 的冪次分級快取），支援 `crop`、`scale` 翻轉與圓角。
- **縮圖（`BoardPreview`）**：最長邊 1600px、倍率 ≤ 2；`lines` 為前 8 個文字元素；PNG 另存 `<hash>.png`（先寫 PNG 再寫 JSON，PNG 被刪就重新產生），記憶體只留 JSON，PNG 另有 32 MB 上限的快取。已知限制：深色模式反相時，圖片也會被反相。

**畫布與編輯核心（4c）**：

- **編輯核心不依賴平台**：工具狀態、選取、hit test、拖曳 / 縮放 / 建立的手勢狀態機都在畫布座標下運作，只呼叫 `ExcalidrawScene` 的編輯 API，可以用單元測試驗證；iOS（`PKCanvasView`）與 macOS（`NSView`）只負責把觸控 / 滑鼠事件換成畫布座標交給它。layer 樹（`CALayer`）兩個平台共用。
- **無限畫布**：Excalidraw 的座標可以是負數，`PKCanvasView` 的內容座標從 0 開始，所以 `內容座標 = 場景座標 − origin`。開啟時 origin 與 `contentSize` 取「內容範圍外擴一圈留白」；捲到接近邊緣時擴大，origin 變動時筆畫平移、`contentOffset` 跟著補償，畫面不跳動。存檔時把筆畫換回場景座標，檔案裡永遠是場景座標。
- **畫布固定淺色**：結構元素的顏色寫在檔案裡（`#1e1e1e` 等），PencilKit 在深色模式會自動反轉筆畫顏色，兩者會不一致，所以編輯器畫布固定淺色（`overrideUserInterfaceStyle = .light`、背景用 `viewBackgroundColor`）。深色模式（像 Excalidraw 那樣整張反相）之後再做。
- **Undo**：每個結構操作記下受影響元素修改前後的字典，註冊在 `PKCanvasView` 的 `undoManager`（與筆畫共用一個堆疊）。復原時寫回修改前的內容，但 `version` 一律繼續遞增（不回到舊版號），否則其他裝置會以為沒有變動、合併時丟掉復原。

**編輯核心的細節（4c）**：

- **`BoardEditor`**（`KindWhiteboard/Editor/`，`@Observable`）：持有工具、選取與手勢狀態，直接修改 `BoardDocument` 的場景。事件介面只有畫布座標：`tap` / `begin` / `drag` / `end` / `cancel`（加上 Shift），宿主負責換算座標與決定哪些觸控交給它。操作中逐幀修改場景（`version` 跟著遞增，與 Excalidraw 相同），結束時才註冊一筆 Undo、排存檔。
- **存檔**：`BoardDocument.edit` 只改記憶體並標記待存；宿主停止操作 500 ms 後（或離開、外部變動前）`commit` 一次寫入，與筆畫共用同一個計時器。
- **hit test**：最上層優先；有填色的形狀、文字、圖片點內部即可，透明形狀與 frame 只點得到邊框（frame 另含標題），已選取的元素點內部也算；容差是螢幕上固定的點數（除以縮放倍率）。形狀內的文字選到容器；`groupIds` 選到最外層群組的所有元素；`locked` 與手寫不能選（iOS 手寫交給套索，Mac 手寫只能看）。
- **建立圖形**：矩形、橢圓、frame、箭頭都是拖曳建立，拖曳距離太短就不建立；建立後切回選取工具並選取新元素。箭頭起點、終點落在可綁定形狀上（含邊框外一點容差）就綁定；frame 建立時把完全在範圍內的元素收進去。
- **縮放**：單一元素在自身（未旋轉）座標系縮放、對角固定；多選依整體範圍等比例換算每個元素的矩形。每一幀都從開始拖曳時的原始元素計算，不累積誤差。不允許翻轉（最小 1）。單一箭頭顯示兩端控制點，拖曳端點可重新綁定或解除。
- **選取外框**：`SelectionOverlay`（CALayer，兩個平台共用）在 PencilKit 上方、以螢幕座標畫選取框、控制點、框選範圍與綁定目標的提示，所以控制點大小不隨縮放改變。
- **文字編輯**：編輯器只記錄「正在編輯哪段文字」（既有文字、形狀內的文字，或新文字的位置）與開始時的場景；宿主依它在元素上疊原生文字框（iOS `UITextView`、Mac `NSTextView`），字級、行高、顏色、對齊、旋轉與元素相同並跟著縮放，編輯中隱藏該元素的 layer。輸入過程只改文字框，不碰場景（注音組字中不打斷）；結束編輯（點畫布其他地方、換工具、Esc、離開白板）才一次寫回並註冊一筆 Undo。進入方式：文字工具點空白處 → 新文字（插入點在點下的位置垂直置中）；文字工具點文字或形狀、選取工具雙擊文字或形狀 → 編輯該文字 / 形狀內的文字（沒有就新增，`containerId` 綁定）；選取工具雙擊空白處 → 新文字。結束時內容空白：新文字不建立，既有文字刪除（形狀內的文字刪除後形狀保留）。之後切回選取工具並選取該文字（形狀內的文字選取容器）。新文字預設字級 20、`#1e1e1e`。
- **插入圖片**：工具列的「圖片」是選單（照片、檔案、貼上），不是常駐工具。解碼與縮圖（`ExcalidrawScene.downscale`）在背景執行，回主執行緒才插入；圖片中心放在畫面中央，顯示尺寸最長邊約螢幕上 400 點（除以縮放倍率）。插入後切回選取工具並選取圖片，一筆 Undo（`files` 不隨 Undo 移除，與刪除相同）。照片用 `PhotosPicker`（不需要相簿權限）。
- **iOS 工具與手勢**：結構操作時停用 `drawingGestureRecognizer`，由編輯器的拖曳手勢接手（`canvas.panGestureRecognizer` 要等它失敗才捲動）：Pencil 碰哪都算（空白處框選），手指只有碰到元素或控制點才拖曳、空白處維持捲動。

**工具列改版（Freeform 式）**：

- **上方工具列**：畫筆、便條紙、形狀、文字框、圖片；有選取時加上再製、刪除；最後是 Undo / Redo。獨立一排，放在導覽列（檔名、設定）下方、畫布上方（`safeAreaInset(edge: .top)`），iPad 與 iPhone 相同；不放進導覽列（與檔名擠在同一列）。Mac 之後共用（沒有畫筆）。
- **畫筆 = 手寫模式開關**，不是工具：開啟時顯示 `PKToolPicker`（鋼筆、鉛筆、麥克筆、單線筆、橡皮擦、套索、尺；墨水只放這四種，其他墨水存成 freedraw 會失真），Pencil 交給 PencilKit，手指點一下選取、長按才拖曳、雙擊編輯文字。關閉時隱藏工具盤、停用 PencilKit 手勢，Pencil 與手指都是選取。開啟時一定讓 `PKCanvasView` 成為 first responder（文字編輯結束後也是），工具盤才叫得回來。手寫模式記在 `BoardEditor.inking`（平台無關）。
- **插入而不是拖曳建立**：形狀（彈出面板只顯示圖示：矩形、圓角矩形、橢圓、菱形、箭頭、Frame；名稱只給 VoiceOver）、便條紙、文字框都插在畫面中央、選取新元素、一筆 Undo。中央已有同位置的元素時往右下錯開 20，連按不會疊在一起。預設尺寸：形狀 160×160（螢幕點，除以縮放倍率，下同）、箭頭長 200、Frame 400×300（不收進既有元素）。`BoardTool` 的拖曳建立留在編輯核心，給 Mac 與鍵盤快捷鍵用。
- **選取方式：矩形 / 套索**：工具列一個按鈕切換（圖示顯示目前的方式），存在 App 偏好設定（`@AppStorage("whiteboardSelectionShape")`）。只影響非手寫模式下 Pencil 在空白處拖曳的範圍選取；手寫模式的筆畫選取仍是 PencilKit 工具盤的套索。套索在編輯核心是 `.lasso` 手勢，記錄經過的點（相距至少 3 螢幕點），選取「取樣點全部落在套索多邊形內」的元素：形狀取輪廓路徑的節點、線與箭頭取各點、文字與圖片取四角，都套用旋轉；放開時多邊形自動閉合。`SelectionOverlay` 以虛線畫出套索。限制：手寫在 `PKCanvasView`、結構元素在自己的 layer，同一次選取無法同時選到兩者一起移動（要做就得自己實作筆畫的選取與移動，另議）。
- **選其他工具就離開手寫模式**：按便條紙、形狀（選了形狀時）、文字框、圖片（選了來源時）或選取方式按鈕，都會先關閉手寫模式（工具盤隱藏、回到選取），由編輯核心的插入 API 自己設定 `inking = false`。Undo / Redo、再製、刪除不改模式。
- **便條紙**：標準元素組合，excalidraw.com 打得開：無外框的方角 rectangle（`backgroundColor: #ffec99`、`strokeColor: transparent`）200×200，插入後直接編輯其中的文字（`containerId`）。插入與文字各一筆 Undo；沒打字也保留便條紙（與 Freeform 相同）。
- **文字框**：在畫面中央開始一段新文字（不看中央有沒有元素）。
- **畫布背景**：右下角選單：無、網格、點狀。是 App 的偏好設定（`@AppStorage("whiteboardBackground")`，預設點狀），所有白板共用、不寫進檔案：Excalidraw 沒有點狀背景的欄位，自訂 `appState` 欄位會在 excalidraw.com 存檔時被丟掉，也是相容性風險。（曾考慮 Excalidraw 的 `appState.gridModeEnabled`，但它只有網格、還會開啟吸附，語意不同。）只在編輯器顯示，縮圖與嵌入不畫。畫法：兩層 `CAReplicatorLayer`（點或線）放在結構層底下、跟著同一個 transform；間距 20 的 2ⁿ 倍，讓螢幕上的間距至少約 14 點；點的大小與線寬每幀除以縮放倍率，螢幕上維持固定。

**4c：macOS 宿主、快捷鍵、LOD**：

- **macOS 宿主**（`BoardMacCanvasView`，`NSView`）：Mac 沒有 `PKCanvasView`，所以不用 `NSScrollView`，自己管平移與縮放：`origin`（畫面左上角的場景座標）與 `zoom`（0.25…4），螢幕座標 = (場景座標 − origin) × zoom，結構層、背景、`SelectionOverlay` 與 iOS 共用同一套 layer 與 transform 規則。座標本來就以場景為準，所以不需要 `CanvasRegion`（無限畫布免費）。`BoardLayerTree(drawsFreedraw: true)`：手寫由結構層畫（不可選取、不可編輯，但搬動 frame 時會跟著走，存檔時原樣保留）。畫布固定淺色（`appearance = .aqua`），與 iOS 相同。
- **輸入**：雙指捲動 = 平移；⌘ / ⌥ + 捲動、觸控板捏合 = 以游標為中心縮放；滑鼠按下 / 拖曳 / 放開直接交給 `BoardEditor`（`begin` / `drag` / `end`）。沒有移動（< 3 點）的按下視為點選：取消這次操作、還原選取、改呼叫 `tap`（Shift 加減選才正確）；雙擊 = 編輯文字。文字框是 `NSTextView`（注音組字是系統的），用 `bounds` ≠ `frame` 縮放內容，編輯中縮放不改字型、不打斷組字；`cancelOperation` 結束編輯（組字中的 Esc 由輸入法處理）。Undo 用視圖自己的 `UndoManager`（結構操作的堆疊，Mac 沒有筆畫），經 Edit 選單與 ⌘Z 使用。
- **工具列**：沿用 iPad 那一排（`BoardToolbar`，兩個平台同一個 view），Mac 隱藏畫筆；用快捷鍵選了建立工具時，對應的按鈕反白。不放進視窗工具列，避免與 2.5b 的麵包屑、New Document 擠在一起。
- **鍵盤快捷鍵**（平台無關，`BoardShortcut`，Mac 與 iPad 外接鍵盤共用）：V 選取、R 矩形、O 橢圓、A 箭頭、T 文字、F frame（不帶修飾鍵）、Delete / ⌫ 刪除、⌘D 再製、⌘A 全選、⌘C / ⌘X / ⌘V 剪貼簿、Esc（結束文字編輯 → 回到選取工具 → 取消選取）。文字框、手寫模式中不攔截（letters 要打進文字框）。
- **拖曳到邊緣自動捲動**（Mac）：拖曳中（移動、縮放、框選 / 套索、拖曳建立、箭頭端點）游標進入畫面邊緣 32 點內或跑出畫面時，畫面往那個方向捲動，越靠近邊緣越快、最快 900 點 / 秒（`EdgeAutoscroll`，平台無關）。每一幀平移畫面後，把同一個游標位置換成新的畫布座標交給 `BoardEditor.drag`，所以框選範圍、移動中的元素都跟著延伸；放開、Esc 取消或游標回到中間就停。只在有捲動時開 display link。iPad 不做（手指拖曳時另一隻手可以捲動）。
- **游標**（Mac）：建立工具（矩形、橢圓、箭頭、frame）是十字、文字工具是 I 形、選取是箭頭；以 `resetCursorRects` 管理，工具改變時（快捷鍵、工具列、建立完回到選取）以 Observation 追蹤 `editor.tool` 立即更新。
- **拖放圖片**（Mac）：畫布接受 Finder 的圖片檔、檔案承諾（照片 App 等，先收到暫存資料夾再讀）、瀏覽器拖出的圖片資料（PNG / TIFF / JPEG / HEIC）。圖片中心放在放開的位置，多張依序往右下錯開 20 點，每張一筆 Undo；解碼、縮圖與插入走與工具列相同的 `BoardEditor.insertImage(_:center:)`。不接受 `.excalidraw` 等其他檔案（貼上 Excalidraw 元素仍用 ⌘V）。
- **LOD**（`BoardLOD`，兩個平台共用）：縮放倍率 ≤ 0.4 且可見範圍內的元素 > 1,500 個時，以 `SceneRenderer` 在背景把可見範圍（外加一半畫面的緩衝）畫成一張點陣圖，放在結構層位置，結構層改為不建立 layer（已建立的移除）；快照準備好之前仍顯示個別 layer，所以不會空白。縮放或平移時圖片跟著 transform（暫時模糊），停止操作 150 ms 後依新範圍與倍率重畫。倍率回到門檻以上就關閉 LOD、分批重建 layer。iOS 的快照不含手寫（`PKCanvasView` 自己畫）。

**4c：樣式面板**：

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

**4c：箭頭連接點吸附**：

- **連接點**：可綁定的形狀（矩形、菱形、橢圓、文字、圖片）各有 4 個連接點：上、右、下、左邊的中點（`fixedPoint` 為 `[0.5, 0]`、`[1, 0.5]`、`[0.5, 1]`、`[0, 0.5]`，跟著 `angle` 旋轉；橢圓、菱形剛好是四個頂點）。
- **吸附**：拖曳建立箭頭或拖曳箭頭端點時，端點距離某個連接點小於 14 螢幕點（除以縮放倍率）就吸過去：拖曳中端點直接顯示在吸附位置，放開時綁定並寫入該 `fixedPoint`。沒有靠近連接點、但落在形狀上時維持原本的行為（`fixedPoint` = 放開位置投影到形狀上的比例）。範圍可以略超出形狀邊框（連接點在邊上）。
- **端點位置**：`fixedPoint` 是四邊中點時，端點 = 該中點沿那一邊的外法線方向外移 `gap`（不走射線），箭頭從形狀背後過來時也停在指定的那一邊；其他 `fixedPoint` 照舊用射線與「輪廓外擴 gap」的交點。形狀移動、縮放、旋轉後依同一規則重算。
- **提示**：`SelectionOverlay` 在綁定目標上畫出 4 個連接點（白底），吸附中的那個實心放大。
- **不做**：轉折線（elbow）與曲線箭頭的走線，新箭頭仍是兩點直線。

## 筆記卡片放進白板（Heptabase / Obsidian Canvas 式，選做）

難度中等，前提是白板結構層已完成。

- **格式**：用一個 rectangle 元素代表卡片（白底，預設 280×160 螢幕點），`link` 設為 `[[筆記]]`，`customData.easynotes.file` 記錄檔案路徑，標題是綁在矩形內的文字。改名時 `renameLinks` 一併更新三者（標題只在仍等於舊名時才改，使用者改過就不動）。任何檔案類型都可以做成卡片（連結以檔名解析）。在 excalidraw.com 上會優雅降級成一個帶連結的框。
- **插入**：工具列「筆記卡片」彈出檔案選單（`session.index.files()`，可搜尋、不列白板自己），插在畫面中央、選取、一筆 Undo。
- **顯示**：卡片內容是檔案的 `DocumentPreview`（標題 + 前幾行，由該類型外掛的預覽產生，白板不認識檔案類型也不 import 其他外掛）：白板經 `DocumentSession.previewReader` 取得（沿用列表縮圖的 hash 快取），存在 `BoardDocument.cardPreviews`。有預覽的卡片由 `NoteCardPainter` 畫標題（18）與最多 6 行內文（14，一行一列、過長以 … 截斷），綁定的標題文字在 App 內隱藏（檔案裡保留給 excalidraw.com）。沒有預覽（類型沒註冊、讀不到）時照常顯示標題文字。預覽是唯讀的，只在 App 內顯示，縮圖與嵌入不畫。內容改了（`vaultChanged`）、開啟白板、插入卡片、同步合併後都重取。
- **尺寸跟著內容**：行高固定，所以高度 = 上下留白 + 標題 + 內文行數 × 行高（最少 64），不需量測文字；寬度維持使用者設定的值。預覽改變時 `ExcalidrawScene.fitNoteCard` 調整卡片高度並存檔（標題文字重新置中、綁定的箭頭重算）。`customData.easynotes.fit` 記錄上次自動調整的高度：目前高度仍等於 `fit` 才自動調整，使用者手動縮放過（高度 ≠ `fit`）就不再動它。自動調整不進 Undo。
- **互動**：雙擊卡片（`BoardEditor.editText(at:)` 先判斷卡片，不進文字編輯）呼叫宿主的 `openNote`，白板轉給 `DocumentSession.openBeside`；App 在 Mac / iPad 以 `.inspector` 在主內容右側開啟該檔案的編輯器（`VaultStore.sidePath`，編輯器由 Registry 依類型提供，所以不限筆記），側邊檔案也算「開啟中」（收到外部修改、不被 `close`）。換到別的位置、或檔案被刪就關閉；iPhone 沒有側邊面板，改為一般開啟。不做畫布內直接編輯：縮放中的畫布上要同時跑多個 CM6 編輯器，成本高、收益小。
- **互通**：需要與 Obsidian Canvas 互通時，另做 JSON Canvas（`.canvas`）匯出即可，不必多維護一種畫布格式。
