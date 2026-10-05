# EasyNotes

## 文件（來源是 `docs/` 的本地 md，三份內容不重複）

- [Architecture](./docs/architecture/README.md)：現在的設計與理由（不放進度、日期）；README 放跨功能原則與依賴規則，每個功能一個檔（`core` / `ui` / `markdown` / `whiteboard` / `pdf` / `sheets` / `flashcards` / `translation`）
- [Roadmap](./docs/Roadmap.md)：勾選清單、驗收、Bug；進度以勾選為準（不放設計理由）
- [Changelog](./docs/Changelog.md)：給使用者看的版本變更

## 工作流程

- **實作前**：只讀 Roadmap 的「狀態總覽」與目前 Phase 小節，再依「設計」欄讀 `docs/architecture/` 對應的檔案（整份讀，不必 offset / limit）；跨外掛或改 Core 才讀 README 與 `core.md`；同一內容一個 session 只讀一次。
- **實作中**：設計有變動，先改 `docs/architecture/` 對應檔再改程式；直接寫成現行規則，不加日期。
- **實作後**：Roadmap 勾選（沒實際驗證的不勾，寫「尚未驗證」）、Changelog 的 `[Unreleased]` 加一行、測試通過後 commit；三者放同一個 commit。
- **Changelog**：[Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/) 格式、繁體中文，只記使用者看得到的變更（Added / Changed / Fixed…），不記重構、測試、文件、Spike。發版時改成 `## [X.Y.Z] - 日期` 並同步 `MARKETING_VERSION`；打 tag 與 push 先問。
- **Commit**：訊息用  `fix: …` / `docs: …`；只 stage 自己改的檔案（不用 `git add -A`，可能有其他 session 的檔案）；不 push、不 amend。

## 不可違反的規則

- 檔案即真相：資料庫只是可重建的索引。
- 核心（`Packages/EasyNotesCore`）不認識任何檔案類型；功能一律做成編譯期外掛。
- 外掛只依賴 EasyNotesCore / EasyNotesUI，外掛之間不互相 import。
- 打字熱路徑不跨 Swift ⇄ JS Bridge。
- **繁體中文**，注音輸入相容性是必要條件。
- 介面文字不寫死：中文字面值一律經過模組的 `L("…")`（見 [translation.md](./docs/architecture/translation.md)）；路徑、檔名慣例與同步協定的字串是例外，集中成常數並標 `// l10n:fixed`。提交前跑 `./scripts/check-l10n.py`。

## 指令

```sh
(cd web && npm install && npm run build)    # 修改 web/src 後
(cd web && npm test)                        # Web 端單元測試（Node，不需要瀏覽器）
(cd web && node test/ime.e2e.mjs)           # 注音組字 e2e（Chromium 模擬輸入法，需要 playwright；先 npm run build）
(cd web && node test/blocks.e2e.mjs)        # 表格、公式、屬性面板 e2e（同上）
(cd web && node test/sheet.e2e.mjs)         # CSV / TSV 工具列、編輯列、狀態列 e2e（同上）
xcodegen generate                           # 修改 project.yml 後
(cd Packages/EasyNotesCore && swift test)   # 核心單元測試（含同步引擎，用假 backend）
./scripts/test-sync.sh                      # SupabaseSync 整合測試（本地 Supabase，需要 Docker）
./scripts/test-e2e.sh [smoke|sync|perf|all] [mac|ipad]  # E2E（XCUITest，Tests/E2E）；結果在 build/E2E-*.xcresult
supabase db push                            # 把 supabase/migrations 套到雲端專案
./scripts/check-l10n.py                     # 找出沒有經過 L("…") 的中文字面值（提交前）
./scripts/fsrs-vectors.py                   # 重新產生 FSRS 參考向量（升級 swift-fsrs 後，需要 uv）
./scripts/whiteboard-stress.py 1000 <路徑>   # 產生 1,000 個元素的白板（4c 效能驗收）
./scripts/install-mac.sh                    # 本機快速更新 /Applications/EasyNotes.app 並重開（--web 先打包 web/src）
./scripts/make-dmg.sh                       # macOS 只走 DMG 安裝更新 → build/EasyNotes-<版本>.dmg
./scripts/upload-testflight.sh              # iOS / iPadOS 上傳 TestFlight（build 號碼自動遞增；Mac 不走 TestFlight）
```
