import assert from "node:assert/strict";
import { test } from "node:test";
import { columnName, formatNumber, parseNumber, stats } from "../src/sheet/stats";

test("欄名", () => {
  assert.deepEqual([0, 1, 25, 26, 27, 51, 52, 701, 702].map(columnName), ["A", "B", "Z", "AA", "AB", "AZ", "BA", "ZZ", "AAA"]);
});

test("只認純數字", () => {
  assert.equal(parseNumber("42"), 42);
  assert.equal(parseNumber(" -3.5 "), -3.5);
  assert.equal(parseNumber("+7"), 7);
  assert.equal(parseNumber(".5"), 0.5);
  assert.equal(parseNumber("1,234,567.8"), 1234567.8);
  for (const text of ["", " ", "-", ".", "1,23", "12,3456", "12%", "$5", "2026-10-05", "1e5", "abc", "3 個", "1.2.3"]) {
    assert.equal(parseNumber(text), null, text);
  }
});

test("計數、加總、平均", () => {
  assert.deepEqual(stats(["1", "2", "", "蘋果", "3"]), { count: 4, numbers: 3, sum: 6, average: 2 });
  assert.deepEqual(stats(["蘋果", " "]), { count: 1, numbers: 0, sum: 0, average: 0 });
  assert.deepEqual(stats([]), { count: 0, numbers: 0, sum: 0, average: 0 });
});

test("數字顯示修掉浮點誤差", () => {
  assert.equal(formatNumber(0.1 + 0.2, "en"), "0.3");
  assert.equal(formatNumber(1234567.5, "en"), "1,234,567.5");
  assert.equal(formatNumber(2 / 3, "en"), "0.6666666667");
});
