# Changelog

本專案的重要變更都記錄在這裡。格式依 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號依 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

### Added

- 白板：原生 Excalidraw 白板編輯器，檔案維持標準 `.excalidraw`，可在 excalidraw.com 開啟。支援矩形、橢圓、菱形、箭頭、文字、圖片、便條紙、Frame 與 Apple Pencil 手寫。
- 白板：箭頭可綁定形狀，並吸附到形狀上、右、下、左的連接點；形狀移動時箭頭跟著走。
- 白板：Freeform 式上方工具列、樣式面板（填色、外框、文字、透明度）、矩形 / 套索選取、畫布背景（無 / 網格 / 點狀）、無限畫布。
- 白板：開啟中的白板會接收同步與外部工具（例如 Claude Code）寫入的變動，不會被舊內容覆蓋。
- 白板：macOS 可編輯結構元素（滑鼠與觸控板、鍵盤快捷鍵、拖曳到邊緣自動捲動、拖放圖片、工具游標）；手寫只能檢視。
- 白板：文件列表顯示縮圖，Markdown 可用 `![[x.excalidraw]]` 嵌入預覽。
- PDF：開啟 PDF 並顯示標註（筆畫、螢光筆、便利貼），原始 PDF 不被修改；文件列表顯示第 1 頁縮圖與頁數；新增選單「匯入 PDF…」（⌘O）。
- 封面圖片支援貼上剪貼簿的圖片（⌘V）。
- 設定：支援主題切換(Light/Dark/System)

### Changed

- 側邊欄的 Vault 標頭改用 App 圖示。

### Fixed

- 淺色主題下，選擇文件圖示時看不到圖示。
- 使用 SF Symbol 當文件圖示時，編輯器中顯示空白。
- iPhone 直向的複習牌組列表內容超出螢幕。

## [1.0.0] - 2026-10-02

首次發佈（iOS / iPadOS 經 TestFlight；macOS 經 DMG）。

### Added

- Markdown 筆記：Live Preview、`[[連結]]` 與 `[[` 自動完成、連結改名、標籤、全文搜尋、反向連結索引、callout、核取清單、文件頭（封面、圖示、標籤）、浮動格式工具列與 iOS 鍵盤工具列。注音輸入相容。
- 手寫：Apple Pencil 手寫畫面，存成標準 `.excalidraw` 筆畫。
- 檔案即真相：Vault 是磁碟上的真實檔案（macOS：`~/Documents/EasyNotes`），外部工具修改會被偵測並同步。
- 同步：Supabase 跨裝置同步（Mac、iPad、iPhone），離線編輯、Markdown 三方合併、白板元素合併、同步狀態顯示、最近刪除（保留 30 天，可還原）。
- 介面：全新設計系統與外殼（側邊欄、⌘K 快速開啟、文件列表與縮圖、釘選、類型篩選、深色模式），iPhone 改為底部分頁。
- Flashcards：在 Markdown 內以 `::`、`;;`、`{{}}` 寫卡片；FSRS-6 排程（與 Anki 對齊）、牌組與設定 preset、每日上限、複習介面、復原、標籤篩選學習；多裝置複習紀錄自動合併。
- App 圖示。

[Unreleased]: https://github.com/brian-huanggg/easy-notes/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/brian-huanggg/easy-notes/releases/tag/v1.0.0
