# EasyNotes

## 文件（來源是 `docs/` 的本地 md，三份內容不重複）

- [Architecture](./docs/Architecture.md)：現在的設計與理由（不放進度、日期）
- [Roadmap](./docs/Roadmap.md)：勾選清單、驗收、Bug；進度以勾選為準（不放設計理由）
- [Changelog](./docs/Changelog.md)：給使用者看的版本變更

## 工作流程

- **實作前**：只讀 Roadmap 的「狀態總覽」與目前 Phase 小節，再依「設計」欄只讀 Architecture 對應章節（用標題定位、給 offset / limit）；同一內容一個 session 只讀一次。
- **實作中**：設計有變動，先改 Architecture 再改程式；直接寫成現行規則，不加日期。
- **實作後**：Roadmap 勾選（沒實際驗證的不勾，寫「尚未驗證」）、Changelog 的 `[Unreleased]` 加一行、測試通過後 commit；三者放同一個 commit。
- **Changelog**：[Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/) 格式、繁體中文，只記使用者看得到的變更（Added / Changed / Fixed…），不記重構、測試、文件、Spike。發版時改成 `## [X.Y.Z] - 日期` 並同步 `MARKETING_VERSION`；打 tag 與 push 先問。
- **Commit**：訊息用 `Phase 4c: …` / `fix: …` / `docs: …`；只 stage 自己改的檔案（不用 `git add -A`，可能有其他 session 的檔案）；不 push、不 amend。

## 不可違反的規則

- 檔案即真相：資料庫只是可重建的索引。
- 核心（`Packages/EasyNotesCore`）不認識任何檔案類型；功能一律做成編譯期外掛。
- 外掛只依賴 EasyNotesCore / EasyNotesUI，外掛之間不互相 import。
- 打字熱路徑不跨 Swift ⇄ JS Bridge。
- 使用者以**繁體中文**溝通，注音輸入相容性是必要條件。

## 指令

```sh
(cd web && npm install && npm run build)    # 修改 web/src 後
xcodegen generate                           # 修改 project.yml 後
(cd Packages/EasyNotesCore && swift test)   # 核心單元測試（含同步引擎，用假 backend）
./scripts/test-sync.sh                      # SupabaseSync 整合測試（本地 Supabase，需要 Docker）
supabase db push                            # 把 supabase/migrations 套到雲端專案
./scripts/fsrs-vectors.py                   # 重新產生 FSRS 參考向量（升級 swift-fsrs 後，需要 uv）
./scripts/whiteboard-stress.py 1000 <路徑>   # 產生 1,000 個元素的白板（4c 效能驗收）
./scripts/install-mac.sh                    # 本機快速更新 /Applications/EasyNotes.app 並重開（--web 先打包 web/src）
./scripts/make-dmg.sh                       # macOS 只走 DMG 安裝更新 → build/EasyNotes-<版本>.dmg
./scripts/upload-testflight.sh              # iOS / iPadOS 上傳 TestFlight（build 號碼自動遞增；Mac 不走 TestFlight）
```
