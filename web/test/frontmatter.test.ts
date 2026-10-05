// 屬性（frontmatter 頂層欄位）：讀成型別、寫回只動那個欄位
import assert from "node:assert/strict";
import { test } from "node:test";
import { convertValue, readEntries, renameEntry, setEntry } from "../src/markdown/frontmatter";

const sample = [
  "title: 我的筆記",
  "tags:",
  "  - 讀書",
  "  - 'a b'",
  "pinned: true",
  "# 註解",
  "date: 2026-10-05",
  "aliases: [甲, \"乙, 丙\"]",
  "nested:",
  "  a: 1",
  "icon: sf:map",
  "empty:",
];

test("讀取型別", () => {
  const entries = readEntries(sample);
  assert.deepEqual(
    entries.map((e) => [e.key, e.value]),
    [
      ["title", { type: "text", value: "我的筆記" }],
      ["tags", { type: "list", items: ["讀書", "a b"] }],
      ["pinned", { type: "checkbox", value: true }],
      ["date", { type: "date", value: "2026-10-05" }],
      ["aliases", { type: "list", items: ["甲", "乙, 丙"] }],
      ["nested", { type: "raw", value: "a: 1" }],
      ["icon", { type: "text", value: "sf:map" }],
      ["empty", { type: "text", value: "" }],
    ],
  );
  assert.deepEqual(readEntries(["tags: 單一"])[0].value, { type: "list", items: ["單一"] });
  assert.deepEqual(readEntries(["tags:"])[0].value, { type: "list", items: [] });
  assert.deepEqual(readEntries(["url: https://a.b/c"])[0].value, { type: "text", value: "https://a.b/c" });
});

test("寫回：只改那個欄位，其他行（含註解）不變", () => {
  const out = setEntry(sample, "tags", { type: "list", items: ["讀書", "新"] });
  assert.deepEqual(out, [...sample.slice(0, 2), "  - 讀書", "  - 新", ...sample.slice(4)]);
  assert.deepEqual(setEntry(sample, "pinned", { type: "checkbox", value: false })[4], "pinned: false");
  assert.deepEqual(setEntry(sample, "aliases", { type: "list", items: ["甲"] })[7], "aliases: [甲]");
  assert.deepEqual(setEntry(sample, "title", null), sample.slice(1));
  assert.deepEqual(setEntry(sample, "tags", null), [sample[0], ...sample.slice(4)]);
  assert.deepEqual(setEntry(sample, "nested", { type: "raw", value: "x" }), sample, "raw 不改寫");
  assert.deepEqual(setEntry([], "status", { type: "text", value: "" }), ["status:"]);
  assert.deepEqual(setEntry(["a: 1"], "a", { type: "text", value: "true" }), ['a: "true"'], "看起來像布林的文字加引號");
  assert.deepEqual(setEntry(["a: 1"], "a", { type: "text", value: "x: y" }), ['a: "x: y"']);
  assert.deepEqual(setEntry(["tags: [a]"], "tags", { type: "list", items: [] }), ["tags: []"]);
});

test("寫回後讀回相同的值", () => {
  for (const value of ["中文", "a, b", "#tag", "- x", "100", "2026-01-01", "'quote'", 'say "hi"', "x: y"]) {
    const lines = setEntry([], "k", { type: "text", value });
    assert.deepEqual(readEntries(lines)[0].value, { type: "text", value }, value);
    const list = setEntry(["k: [a]"], "k", { type: "list", items: [value] });
    assert.deepEqual(readEntries(list)[0].value, { type: "list", items: [value] }, `flow ${value}`);
  }
});

test("改名只動冒號前", () => {
  assert.deepEqual(renameEntry(["title: 一 # 註解", "b: 2"], "title", "標題"), ["標題: 一 # 註解", "b: 2"]);
  assert.deepEqual(renameEntry(["a: 1", "b: 2"], "a", "b"), ["a: 1", "b: 2"], "撞名不改");
});

test("換型別保留內容", () => {
  assert.deepEqual(convertValue({ type: "text", value: "a, b" }, "list"), { type: "list", items: ["a", "b"] });
  assert.deepEqual(convertValue({ type: "list", items: ["a", "b"] }, "text"), { type: "text", value: "a, b" });
  assert.deepEqual(convertValue({ type: "text", value: "2026-10-05" }, "date"), { type: "date", value: "2026-10-05" });
});
