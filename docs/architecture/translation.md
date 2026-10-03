# 多語言（在地化）

支援 `zh-Hant`（繁體中文）與 `en`（English (US)）。**來源語言是 zh-Hant**：程式裡寫的中文就是 key，`en` 是翻譯。

## 語言選擇

- 預設跟隨系統語言；系統語言不在支援清單時用 English（`CFBundleDevelopmentRegion = en`，`CFBundleLocalizations = [zh-Hant, en]`）。
- iOS / iPadOS：用系統「設定 > EasyNotes > 語言」，App 內不做選擇器（Apple 的標準做法，少一份要維護的 UI）。
- macOS：設定（⌘,）提供語言選項，寫入 `UserDefaults` 的 `AppleLanguages`，**重新啟動後生效**。
- 不做執行中即時切換：`String(localized:)` 與 AppKit 選單在建立當下就解析成字串，要即時切換得自己換 bundle、重建所有畫面與 WebView，換來的只是一個很少用的功能。

## 字串資源

每個有中文的模組自帶一份 `Localizable.xcstrings`（String Catalog）：App、`EasyNotesCore`、`EasyNotesUI`、`ExcalidrawKit`、各外掛、`Flashcards`。

- 外掛的字串在外掛裡，拿掉外掛就一起拿掉，也符合「Core 不認識外掛」。Core 與 EasyNotesUI 是同一個 package 的兩個 target，各有自己的 catalog。
- 檔案放在 target 根目錄（`Sources/<Target>/Localizable.xcstrings`），`Package.swift` 設 `defaultLocalization: "zh-Hant"` 與 `resources: [.process("Localizable.xcstrings")]`。
- key 是 zh-Hant 原文。理由：編譯器直接從程式碼擷取、不必另外發明 key、zh-Hant 畫面與沒有本地化時完全相同。含插值的 key 會被擷取成 `%lld 份文件`、`%@ 字`。
- 同一句中文在不同語境要不同英文時，把中文原文寫得不同（「完成」→「完成編輯」），不用 comment 區分；comment 只用來給翻譯者背景。

## 程式寫法

`Text("…")`、`Button("…")` 的字面值預設查 **main bundle**，在 package 裡找不到自己的 catalog（字面值轉成 `LocalizedStringResource` 也一樣）。所以每個模組放一個 `L(_:)`，把字面值綁到自己的 bundle：

```swift
// <Target>/Localization.swift（每個模組一份；#bundle 要在該模組展開，不能共用）
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: #bundle)
}
```

`L` 回傳已解析的 `String`，所以任何接受 `String` 的地方都能用，元件 API 不必改型別。因為不做即時切換，字串在呼叫當下解析即可，不需要 `LocalizedStringResource` 的延遲解析。

| 情境 | 寫法 |
| --- | --- |
| SwiftUI 文字、按鈕、標題、`help` | `Text(L("標題"))`、`Button(L("儲存"))`、`.help(L("說明"))` |
| 插值 | `L("\(count) 份文件")`；不要先拼成 `String` 再傳入 |
| 元件 API、回傳值、錯誤訊息 | 同樣用 `L("…")`，參數型別維持 `String` |
| 複數 | 在 catalog 為該 key 加 plural variations（`en` 需要 one / other） |
| 日期、數字、相對時間 | 用 `Date.formatted`、`RelativeDateTimeFormatter`、`Intl.*`，不手拼；不寫死 `Locale(identifier: "zh-Hant")` |
| 使用者看不到的字串 | 日誌、`precondition` 訊息、`#Preview` 示範資料、`Spike/` 資料夾的驗證用面板不翻 |

`L(…)` 的參數型別是 `String.LocalizationValue`，編譯器認得它，擷取時 key 與插值都正確。**新程式碼不寫沒有經過 `L(…)` 的中文字面值**，`scripts/check-l10n.py` 會檢查。

## 不隨語言改變的字串

這些字串是資料或協定，隨語言改變會讓同一個 Vault 在不同語言的裝置上行為不一致。集中成常數，行尾標 `// l10n:fixed` 告訴檢查腳本是刻意的。

| 字串 | 原因 |
| --- | --- |
| 資料夾與檔名慣例：`Attachments/`（舊版的 `附件/` 只讀取）、`.easynotes/`、`CLAUDE.md` | 路徑會被連結引用、跨裝置同步、被 Claude Code 讀取 |
| 衝突副本檔名 `<名稱> (衝突 <裝置> <日期>).<副檔名>` | 同步引擎產生、App 以前綴辨識並跨裝置同步；兩台不同語言的裝置必須認得同一種 |
| 檔案格式內的文字：frontmatter 鍵、卡片語法、`.excalidraw` / `.pdf.ink` / `.jsonl` 的欄位 | 開放格式，其他工具要讀 |
| Vault 的 `CLAUDE.md` 內容（固定用英文） | 給 Claude Code 讀；只在檔案不存在時建立，若隨 UI 語言，兩台不同語言的裝置會各自建出不同內容而產生衝突副本。內容裡的範例（卡片語法、路徑）也用英文，附件路徑寫 `Attachments/` |

**建立當下的預設值**用當下的 UI 語言產生，之後就是使用者的檔案，不再改寫：新檔案的預設檔名（「未命名」「白板」）、新資料夾、貼上的圖片檔名、首次啟動的範例內容。

## 索引裡的顯示文字

`DocumentKind.index()` 的 `summary`（「123 字」「N 頁」「N 個元素」）是顯示用文字，Core 只存不解讀，所以內容帶著產生當下的 UI 語言。索引記錄產生它時的語言；語言與目前不同時，整份索引重建（索引本來就可重建，語言切換很少發生）。標題、全文、連結不受語言影響。

## WebView 外掛

- Swift 在建立 `WebEditorHost` 時把語言識別碼當一次性參數傳給 JS，不經過打字路徑。
- JS 端的字串集中在 `web/src/shared/i18n.ts`：`t(key, params)`，key 同樣用 zh-Hant 原文，查不到就回傳 key；各語言一份字典。
- 相對時間、數字、日期用 `Intl.RelativeTimeFormat` / `Intl.NumberFormat` / `Intl.DateTimeFormat`，不手拼「N 分鐘前」。
- 傳進 JS 的資料不含已翻譯的文字，由 JS 依語言組成（例如 Swift 傳 `modified` 時間戳，JS 組「N 分鐘前更新」）。

## 驗證

- `scripts/check-l10n.py`：列出沒有經過 `L(…)` / `t(…)` 也沒有 `// l10n:fixed` 的中文字面值；提交前跑。
- Xcode scheme 的 Double-Length Pseudolanguage 檢查版面是否被撐壞；Right-to-Left Pseudolanguage 檢查 leading / trailing 用法。
- catalog 內每個 `en` 條目的狀態不是 `translated` 就代表漏翻。
