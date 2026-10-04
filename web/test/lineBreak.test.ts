// 換行符與 frontmatter：未修改的部分逐位元組寫回（CRLF、混合換行、檔尾無換行）
import assert from "node:assert/strict";
import { test } from "node:test";
import { EditorState } from "@codemirror/state";
import { frontmatterChange } from "../src/markdown/docHeader";
import { lineBreakExtension, lineBreakOf, replaceChange } from "../src/markdown/lineBreak";

// 與 main.ts 的 load 相同的建立方式
const open = (text: string) => EditorState.create({ doc: text, extensions: lineBreakExtension(text) });

test("偵測換行符：只有全部是 CRLF 才沿用", () => {
  assert.equal(lineBreakOf("a\nb\n"), "\n");
  assert.equal(lineBreakOf("a\r\nb\r\n"), "\r\n");
  assert.equal(lineBreakOf("a\r\nb"), "\r\n");
  assert.equal(lineBreakOf("a\r\nb\n"), "\n");
  assert.equal(lineBreakOf("a\rb"), "\n");
  assert.equal(lineBreakOf(""), "\n");
});

const unchanged = [
  "",
  "# 標題\n\n內容\n",
  "# 標題\r\n\r\n內容\r\n",
  "# 標題\r\n\r\n檔尾無換行",
  "---\r\ntags: [a]\r\n---\r\n本文\r\n",
  "中文 emoji 😀 👨‍👩‍👧\n",
];

test("開啟後不修改，寫回逐位元組相同", () => {
  for (const text of unchanged) assert.equal(open(text).sliceDoc(), text);
});

test("CRLF 檔案打字後仍是 CRLF，只多出打的字", () => {
  const state = open("一\r\n二\r\n三\r\n");
  const line = state.doc.line(2);
  const edited = state.update({ changes: { from: line.to, insert: "（改）" } }).state;
  assert.equal(edited.sliceDoc(), "一\r\n二（改）\r\n三\r\n");
  const split = edited.update({ changes: { from: edited.doc.line(3).to, insert: edited.lineBreak + "四" } }).state;
  assert.equal(split.sliceDoc(), "一\r\n二（改）\r\n三\r\n四\r\n");
});

test("混合換行統一成 \\n（CodeMirror 預設）", () => {
  assert.equal(open("a\r\nb\nc").sliceDoc(), "a\nb\nc");
});

// 換行符不同（例如外部工具把 LF 轉成 CRLF）時 main.ts 重建 state，不走 replaceChange
test("套用遠端變更：CRLF 檔案只改變動的那段", () => {
  for (const [before, after] of [
    ["一\r\n二\r\n三\r\n", "一\r\n二（遠端）\r\n三\r\n"],
    ["一\r\n二\r\n", "一\r\n新增\r\n兩行\r\n二\r\n"],
    ["一\r\n二\r\n三\r\n", "一\r\n三\r\n"],
    ["一\n二\n", "一\n二（遠端）\n"],
    ["一\r\n", "一\r\n\r\n二\r\n"],
  ]) {
    const state = open(before);
    assert.equal(state.update({ changes: replaceChange(state.doc, after) }).state.sliceDoc(), after);
  }
});

test("設定封面再移除：回到原本的位元組（LF 與 CRLF）", () => {
  for (const text of ["內容\n", "內容\r\n", "---\ntags: [a]\n---\n內容\n", "---\r\ntags: [a]\r\n---\r\n內容\r\n"]) {
    let state = open(text);
    state = state.update({ changes: frontmatterChange(state, "cover", "Attachments/a b.png")! }).state;
    assert.ok(state.sliceDoc().includes("cover: "));
    state = state.update({ changes: frontmatterChange(state, "cover", null)! }).state;
    assert.equal(state.sliceDoc(), text);
  }
});

test("設定圖示只多出 frontmatter 那一行，其餘逐位元組相同", () => {
  const body = "# 標題\r\n\r\n內容 [[連結]]\r\n";
  const front = "---\r\ntags: [a, b]\r\ncustom: 保留 # 註解\r\n---\r\n";
  const state = open(front + body);
  const out = state.update({ changes: frontmatterChange(state, "icon", "sf:map")! }).state.sliceDoc();
  assert.ok(!/(^|[^\r])\n/.test(out), "沒有單獨的 \\n");
  assert.equal(out.replace(/icon: [^\r]*\r\n/, ""), front + body);
});
