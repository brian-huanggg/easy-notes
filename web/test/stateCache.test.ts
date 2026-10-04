// EditorState 快取：只保留最近 N 篇
import assert from "node:assert/strict";
import { test } from "node:test";
import { StateCache } from "../src/markdown/stateCache";

test("超過上限時丟掉最久沒用的", () => {
  const cache = new StateCache<number>(3);
  for (const id of ["a", "b", "c", "d"]) cache.set(id, 1);
  assert.equal(cache.size, 3);
  assert.equal(cache.get("a"), undefined);
  assert.equal(cache.get("d"), 1);
});

test("get 會更新使用順序", () => {
  const cache = new StateCache<number>(3);
  for (const id of ["a", "b", "c"]) cache.set(id, 1);
  cache.get("a");
  cache.set("d", 1);
  assert.equal(cache.get("b"), undefined);
  assert.equal(cache.get("a"), 1);
});

test("開過 30 篇後只保留 20 篇", () => {
  const cache = new StateCache<number>(20);
  for (let i = 0; i < 30; i++) cache.set(`n${i}`, i);
  assert.equal(cache.size, 20);
  assert.equal(cache.get("n9"), undefined);
  assert.equal(cache.get("n10"), 10);
});

test("delete 與 clear", () => {
  const cache = new StateCache<number>(3);
  cache.set("a", 1);
  cache.set("b", 2);
  cache.delete("a");
  assert.equal(cache.size, 1);
  cache.clear();
  assert.equal(cache.size, 0);
});
