// 表格：解析、改一格只動那一格、列欄操作後寫回
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  cellChange,
  deleteColumn,
  deleteRow,
  insertColumn,
  insertRow,
  moveRow,
  parseTable,
  serializeTable,
  setAlign,
  splitRow,
} from "../src/markdown/table";

const apply = (line: string, c: { from: number; to: number; insert: string }) => line.slice(0, c.from) + c.insert + line.slice(c.to);

test("切開一行：開頭結尾的 | 可省略、\\| 不切", () => {
  assert.deepEqual(splitRow("| a | b |").map((c) => c.text), ["a", "b"]);
  assert.deepEqual(splitRow("a | b").map((c) => c.text), ["a", "b"]);
  assert.deepEqual(splitRow("| a \\| x | b |").map((c) => c.text), ["a | x", "b"]);
  assert.deepEqual(splitRow("|  | 中文 |").map((c) => c.text), ["", "中文"]);
  assert.deepEqual(splitRow("| 一格 |").map((c) => c.text), ["一格"]);
});

test("解析：對齊、欄數不足補空格、多出的忽略", () => {
  const model = parseTable(["| 名稱 | 數量 | 備註 |", "| :--- | ---: | :-: |", "| 蘋果 | 3 |", "| a | b | c | d |"]);
  assert.deepEqual(model, {
    header: ["名稱", "數量", "備註"],
    align: ["left", "right", "center"],
    rows: [["蘋果", "3", ""], ["a", "b", "c"]],
  });
  assert.equal(parseTable(["| a |", "| b |"]), null);
});

test("改一格：其餘位元組不變", () => {
  assert.equal(apply("| 一 | 二 |", cellChange("| 一 | 二 |", 1, "貳")), "| 一 | 貳 |");
  assert.equal(apply("|一|二|", cellChange("|一|二|", 0, "壹")), "|壹|二|");
  assert.equal(apply("|  | 二 |", cellChange("|  | 二 |", 0, "新")), "| 新 | 二 |");
  assert.equal(apply("||二|", cellChange("||二|", 0, "新")), "| 新 |二|");
  assert.equal(apply("| 一 | 二 |", cellChange("| 一 | 二 |", 0, "")), "|  | 二 |");
  assert.equal(apply("| a | b |", cellChange("| a | b |", 0, "x|y")), "| x\\|y | b |");
  // 這一列少一格：補上
  assert.equal(apply("| a |", cellChange("| a |", 2, "c")), "| a |   | c |");
  assert.equal(apply("a | b", cellChange("a | b", 2, "c")), "a | b | c |");
});

test("列欄操作後寫回", () => {
  const model = parseTable(["| a | b |", "| --- | --- |", "| 1 | 2 |"])!;
  assert.deepEqual(serializeTable(model), ["| a | b |", "| --- | --- |", "| 1 | 2 |"]);
  assert.deepEqual(serializeTable(insertRow(model, 0)), ["| a | b |", "| --- | --- |", "|  |  |", "| 1 | 2 |"]);
  assert.deepEqual(serializeTable(deleteRow(model, 0)), ["| a | b |", "| --- | --- |"]);
  assert.deepEqual(serializeTable(insertColumn(model, 1)), ["| a |  | b |", "| --- | --- | --- |", "| 1 |  | 2 |"]);
  assert.deepEqual(serializeTable(deleteColumn(model, 0)), ["| b |", "| --- |", "| 2 |"]);
  assert.deepEqual(serializeTable(deleteColumn(deleteColumn(model, 0), 0)), ["| b |", "| --- |", "| 2 |"], "最後一欄不刪");
  assert.deepEqual(serializeTable(setAlign(model, 1, "center")), ["| a | b |", "| --- | :---: |", "| 1 | 2 |"]);
  const two = insertRow(model, 1);
  assert.deepEqual(moveRow(two, 0, 1).rows, [["", ""], ["1", "2"]]);
});

test("格內 md 渲染：跳脫 HTML、粗體、程式碼內不處理", async () => {
  const { renderInline } = await import("../src/markdown/tableWidget");
  assert.equal(renderInline("**黃色**"), "<strong>黃色</strong>");
  assert.equal(renderInline("<b>x</b>"), "&lt;b&gt;x&lt;/b&gt;");
  assert.equal(renderInline("a<br>b"), "a<br>b");
  assert.equal(renderInline("`**x**`"), '<code class="cm-lp-code">**x**</code>');
  assert.equal(renderInline("[[筆記|別名]] *斜*"), '<span class="cm-lp-wikilink">別名</span> <em>斜</em>');
  assert.equal(renderInline("snake_case_name"), "snake_case_name");
  assert.equal(renderInline("$5 和 $10"), "$5 和 $10");
});
