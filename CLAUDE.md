# EasyNotes

開始任何工作前，先讀架構文件（Claude Docs）：
https://claude.ai/code/artifact/7320e690-9586-41ee-88ac-17192f62f8c5

- 用 Claude Docs connector 讀取（`read` → project id `7320e690-9586-41ee-88ac-17192f62f8c5`），不要用 WebFetch。
- 目前進度以文件中「Roadmap 與 Todo」的勾選狀態為準；完成項目後回去勾選。
- 架構決策有變動時，先更新文件再改程式。

## 不可違反的規則

- 檔案即真相：資料庫只是可重建的索引。
- 核心（`Packages/EasyNotesCore`）不認識任何檔案類型；功能一律做成編譯期外掛。
- 外掛只依賴 EasyNotesCore / EasyNotesUI，外掛之間不互相 import。
- 打字熱路徑不跨 Swift ⇄ JS Bridge。
- 使用者以繁體中文溝通，注音輸入相容性是必要條件。

## 指令

```sh
(cd web && npm install && npm run build)    # 修改 web/src 後
xcodegen generate                           # 修改 project.yml 後
(cd Packages/EasyNotesCore && swift test)   # 核心單元測試
```
