// 卡片語法中的公式保護與克漏字（與 Swift 端 CardSyntaxTests 的案例相同）
import assert from "node:assert/strict";
import { test } from "node:test";
import { blockEnd, blockHead, clozeMatches, mathSpans } from "../src/markdown/cardSyntax";

const spans = (text: string, inCode?: (o: number) => boolean) =>
  mathSpans(text, inCode).map((m) => (m.display ? "D:" : "I:") + text.slice(m.from, m.to));
const answers = (text: string, inCode?: (o: number) => boolean) => clozeMatches(text, inCode).map((m) => m.answer);

test("行內與獨立公式", () => {
  assert.deepEqual(spans("能量 $E=mc^2$ 與 $$\\int_0^1 x\\,dx$$"), ["I:$E=mc^2$", "D:$$\\int_0^1 x\\,dx$$"]);
});

test("金額不是公式", () => {
  assert.deepEqual(spans("$5 和 $10"), []);
  assert.deepEqual(spans("花了 $5, 剩 $10."), []);
  assert.deepEqual(spans("$ x$ 與 $x $"), []);
  assert.deepEqual(spans("$x$5"), []);
  assert.deepEqual(spans("$$ $$"), []);
});

test("跳脫的 $ 不是分隔符", () => {
  assert.deepEqual(spans("\\$x$"), []);
  assert.deepEqual(spans("$a\\$b$"), ["I:$a\\$b$"]);
});

test("程式碼中的 $ 不算", () => {
  const text = "`$x$` 與 $y$";
  assert.deepEqual(spans(text, (o) => o < 5), ["I:$y$"]);
  // 公式不能跨進程式碼
  assert.deepEqual(spans("$a `b$`", (o) => o >= 3), []);
});

test("克漏字可以包住含大括號的公式", () => {
  assert.deepEqual(answers("{{$\\frac{a}{b}$}} 是分數"), ["$\\frac{a}{b}$"]);
  assert.deepEqual(answers("{{粒線體}}是{{細胞的發電廠}}"), ["粒線體", "細胞的發電廠"]);
});

test("公式中的 {{ }} 不是克漏字", () => {
  assert.deepEqual(answers("$\\frac{{a}}{b}$"), []);
  assert.deepEqual(answers("$x$ 與 {{y}}"), ["y"]);
});

test("克漏字其餘規則與原本的正規表示式相同", () => {
  assert.deepEqual(answers("{{}}"), []);
  assert.deepEqual(answers("{{ }}"), [" "]);
  assert.deepEqual(answers("{{{a}}"), ["a"]);
  assert.deepEqual(answers("{{a}}}"), ["a"]);
  assert.deepEqual(answers("{{a}b}}"), []);
  assert.deepEqual(answers("{{a\nb}}"), []);
  // 程式碼中的 {{ }} 不算；克漏字可以完整包住程式碼，不能只包一半
  assert.deepEqual(answers("`{{b}}` 與 {{c}}", (o) => o < 7), ["c"]);
  assert.deepEqual(answers("{{a `b`}}", (o) => o >= 4 && o < 7), ["a `b`"]);
  assert.deepEqual(answers("{{a `b}} c`", (o) => o >= 4), []);
});

test("多行 note 的首行（與 Swift 端 MultilineCardTests 相同）", () => {
  assert.deepEqual(blockHead("- 問 :: ^c-a1b2c3"), { column: 2, sepFrom: 4, bidirectional: false });
  assert.deepEqual(blockHead("1. 中文 ;;"), { column: 3, sepFrom: 6, bidirectional: true });
  assert.equal(blockHead("\t- tab ::")?.column, 6);
  assert.equal(blockHead("段落 ::"), null);
  assert.equal(blockHead("> - 引言 ::"), null);
  assert.equal(blockHead("- ::"), null);
  assert.equal(blockHead("- 問 :: 答"), null);
  assert.equal(blockHead("- `a ::`", (o) => o >= 2), null);
  assert.equal(blockHead("- $a ::$"), null);
});

test("多行 note 的子行範圍", () => {
  const lines = ["- 問 ::", "  答一", "", "  - 答二", "", "- 下一個"];
  const at = (n: number) => lines[n] ?? null;
  assert.equal(blockEnd(at, 0, 2), 3);
  assert.equal(blockEnd(at, 5, 2), 5);
  const ordered = ["1. 編號 ::", "   答案", "  不足三欄"];
  assert.equal(blockEnd((n) => ordered[n] ?? null, 0, 3), 1);
});
