# EasyNotes

本地優先、檔案即真相的筆記 App（iOS / iPadOS / macOS）。架構與技術方案見
[EasyNotes 架構與技術方案](./docs/architecture/README.md) 以及 [待辦事項](./docs/Roadmap.md)。

## 結構

| 路徑 | 內容 |
| --- | --- |
| `App/` | SwiftUI 外殼、編輯器（WebView / PencilKit）、VaultStore |
| `App/Resources/Editor/` | 打包後的 CodeMirror 6 編輯器（`index.html` + `editor.js`，由 `web/` 產生） |
| `web/` | CodeMirror 6 + Live Preview + Swift Bridge 原始碼（TypeScript） |
| `Packages/EasyNotesCore/` | 核心：Vault 檔案操作、DocumentKind、Markdown 索引、PencilKit ⇄ Excalidraw |
| `project.yml` | XcodeGen 設定（`EasyNotes.xcodeproj` 由它產生） |

## 開發

```sh
brew install xcodegen
pnpm install && (cd web && pnpm build)   # 修改 web/src 後需重新 build
xcodegen generate && open EasyNotes.xcodeproj
(cd Packages/EasyNotesCore && swift test)  # 核心單元測試（含 Spike S2）
```

Vault 位置：macOS `~/Documents/EasyNotes`；iOS 為 App 的 Documents（「檔案」App 可見）。
Debug build 可用 Safari → 開發 → 檢查 WebView 除錯編輯器。
