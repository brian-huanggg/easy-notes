# EasyNotes

開始任何工作前，先讀架構文件（Claude Docs）：
- [Architecture](./docs/Architecture.md)
- [Roadmap](./docs/Roadmap.md)

- 目前進度以[Roadmap](./docs/Roadmap.md)的勾選狀態為準；完成項目後回去勾選。
- 架構決策有變動時，先更新文件再改程式。

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
```
