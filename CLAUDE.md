# EasyNotes

## 文件（來源是 `docs/` 的本地 md，三份內容不重複）

- [Architecture](./docs/architecture/README.md)：現在的設計與理由（不放進度、日期）；README 放跨功能原則與依賴規則，每個功能一個檔（`core` / `ui` / `markdown` / `whiteboard` / `pdf` / `sheets` / `flashcards` / `translation`）
- [Roadmap](./docs/Roadmap.md)：勾選清單、驗收、Bug；進度以勾選為準（不放設計理由）
- [Changelog](./docs/Changelog.md)：給使用者看的版本變更（由 commit 訊息產生，不手改）

## 工作流程

- **實作前**：只讀 Roadmap 的「狀態總覽」與目前 Phase 小節，再依「設計」欄讀 `docs/architecture/` 對應的檔案（整份讀，不必 offset / limit）；跨外掛或改 Core 才讀 README 與 `core.md`；同一內容一個 session 只讀一次。
- **實作中**：設計有變動，先改 `docs/architecture/` 對應檔再改程式；直接寫成現行規則，不加日期。
- **實作後**：Roadmap 勾選（沒實際驗證的不勾，寫「尚未驗證」）、測試通過後 commit；Roadmap 與程式放同一個 commit。**不要手改 Changelog**：它由 commit 訊息產生（見下）。
- **Commit**：[Conventional Commits](https://www.conventionalcommits.org/zh-hant/v1.0.0/)，格式 `type: 主旨`，由 `.githooks/commit-msg`（commitlint）檢查，不合格式的 commit 會被擋下。type 決定 Changelog：
  - 進 Changelog：`feat`（Added）、`fix`（Fixed）、`perf`（Changed）、`security`（Security）。**主旨就是使用者看到的那一行**：繁體中文、寫使用者看得到的變化（「表格可以拖曳排序」），不寫實作細節（「重構 X」「加入 Y 測試」）。
  - 不進 Changelog：`docs`、`refactor`、`test`、`chore`、`build`、`ci`、`style`、`revert`；使用者看不到的修正（腳本、測試、內部重構）用這些 type，不要用 `fix`。
  - 主旨 ≤ 100 字；細節放內文。只 stage 自己改的檔案（不用 `git add -A`，可能有其他 session 的檔案）；不 push、不 amend。
- **發版**（設計見 [README](./docs/architecture/README.md)「發版流程」）：
  1. `./scripts/release.sh`：測試、由 commit 產生 Changelog、更新 `MARKETING_VERSION`、「新功能」內容，建立 `chore(release): vX.Y.Z` commit 與 tag（本機，不 push；`--dry-run` 先預覽）。
  2. `./scripts/publish-release.sh`：打包 DMG、簽章 appcast、push、建立 GitHub Release（`--testflight` 一併上傳 iOS / iPadOS）。push 與建立 Release 是對外的動作，**先問使用者**；不要加 `--yes` 繞過確認。
  - 版本號只改 `project.yml` 的 `MARKETING_VERSION`（由 `release.sh` 改），不手改；不手動打 tag。

## 不可違反的規則

- 檔案即真相：資料庫只是可重建的索引。
- 核心（`Packages/EasyNotesCore`）不認識任何檔案類型；功能一律做成編譯期外掛。
- 外掛只依賴 EasyNotesCore / EasyNotesUI，外掛之間不互相 import。
- 打字熱路徑不跨 Swift ⇄ JS Bridge。
- **繁體中文**，注音輸入相容性是必要條件。
- 介面文字不寫死：中文字面值一律經過模組的 `L("…")`（見 [translation.md](./docs/architecture/translation.md)）；路徑、檔名慣例與同步協定的字串是例外，集中成常數並標 `// l10n:fixed`。提交前跑 `./scripts/check-l10n.py`。

## 指令

```sh
npm install                                 # 根目錄：安裝 commitlint、git-cliff，並啟用 commit-msg hook（clone 後先跑一次）
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
