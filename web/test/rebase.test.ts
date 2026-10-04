// 外部修改或同步推進來時，還沒存檔的本地修改不被覆蓋
import assert from "node:assert/strict";
import { test } from "node:test";
import { ChangeSet, EditorState } from "@codemirror/state";
import { lineBreakExtension } from "../src/markdown/lineBreak";
import { rebase } from "../src/markdown/rebase";

const open = (text: string) => EditorState.create({ doc: text, extensions: lineBreakExtension(text) });


function apply(savedText: string, edits: { from: number; to?: number; insert: string }[], remote: string) {
  const base = open(savedText);
  const tr = base.update({ changes: edits });
  const result = rebase(base.doc, tr.changes, remote);
  const after = tr.state.update({ changes: result.changes }).state;
  return { after, result };
}

test("本地改第一行、遠端改最後一行 → 兩邊都保留", () => {
  const { after } = apply("一\n二\n三\n", [{ from: 1, insert: "（本地）" }], "一\n二\n三（遠端）\n");
  assert.equal(after.sliceDoc(), "一（本地）\n二\n三（遠端）\n");
});

test("CRLF 文件：結果仍是 CRLF", () => {
  const { after } = apply("一\r\n二\r\n", [{ from: 1, insert: "（本地）" }], "一\r\n二（遠端）\r\n");
  assert.equal(after.sliceDoc(), "一（本地）\r\n二（遠端）\r\n");
});

test("兩邊改同一處：不遺失任何一邊的字", () => {
  const { after } = apply("abc\n", [{ from: 1, insert: "L" }], "aRbc\n");
  const out = after.sliceDoc();
  assert.ok(out.includes("L") && out.includes("R"), out);
});

test("本地刪除一段、遠端在其他地方新增", () => {
  const { after } = apply("一\n二\n三\n", [{ from: 2, to: 4 }], "一\n二\n三\n四\n");
  assert.equal(after.sliceDoc(), "一\n三\n四\n");
});

test("新的 saved 是磁碟內容，剩下的本地修改套上去等於目前的文件", () => {
  const { after, result } = apply("一\n二\n三\n", [{ from: 1, insert: "（本地）" }], "零\n一\n二\n三\n");
  assert.equal(result.saved.toString(), "零\n一\n二\n三\n");
  assert.equal(result.unsaved.apply(result.saved).toString(), after.doc.toString());
  assert.ok(!result.unsaved.empty);
});

test("沒有本地修改：直接變成遠端內容", () => {
  const base = open("一\n二\n");
  const result = rebase(base.doc, ChangeSet.empty(base.doc.length), "一\n二（遠端）\n");
  assert.equal(base.update({ changes: result.changes }).state.sliceDoc(), "一\n二（遠端）\n");
  assert.ok(result.unsaved.empty);
});
