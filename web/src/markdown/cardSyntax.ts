// 卡片語法的純函式（不碰 DOM），規則與 Swift 端 Flashcards 的 CardSyntax 一致：
//   公式 `$…$`、`$$…$$` 與行內程式碼一樣受保護，裡面的 `::`、`;;`、`{{`、`}}` 不算卡片語法
//   克漏字的 `{{`、`}}` 要在公式與程式碼之外；內容中的 `{`、`}` 只能出現在公式裡
// `inCode(offset)`：該位置是否在行內程式碼中（編輯器由語法樹判斷）

export interface MathSpan {
  from: number;
  to: number;
  display: boolean;
}

export interface ClozeMatch {
  from: number;
  to: number;
  answer: string;
}

const isSpace = (c: string | undefined) => c !== undefined && /\s/.test(c);
const isDigit = (c: string | undefined) => c !== undefined && c >= "0" && c <= "9";

/// 開頭的 `$` 後面不能是空白，結尾的 `$` 前面不能是空白、後面不能是數字；`\` 後面的字元不當作分隔符
export function mathSpans(text: string, inCode: (offset: number) => boolean = () => false): MathSpan[] {
  const spans: MathSpan[] = [];
  let i = 0;
  while (i < text.length) {
    if (inCode(i)) {
      i++;
      continue;
    }
    if (text[i] === "\\") {
      i += 2;
      continue;
    }
    if (text[i] !== "$") {
      i++;
      continue;
    }
    if (text[i + 1] === "$" && !inCode(i + 1)) {
      const close = closing(text, i + 2, true, inCode);
      if (close !== null && text.slice(i + 2, close).trim()) {
        spans.push({ from: i, to: close + 2, display: true });
        i = close + 2;
      } else {
        i += 2;
      }
      continue;
    }
    const close = i + 1 < text.length && !isSpace(text[i + 1]) ? closing(text, i + 1, false, inCode) : null;
    if (close !== null) {
      spans.push({ from: i, to: close + 1, display: false });
      i = close + 1;
    } else {
      i++;
    }
  }
  return spans;
}

function closing(text: string, start: number, display: boolean, inCode: (offset: number) => boolean): number | null {
  for (let j = start; j < text.length; j++) {
    if (inCode(j)) return null;
    if (text[j] === "\\") {
      j++;
      continue;
    }
    if (text[j] !== "$") continue;
    if (display) {
      if (text[j + 1] === "$" && !inCode(j + 1)) return j;
    } else if (j > start && !isSpace(text[j - 1]) && !isDigit(text[j + 1])) {
      return j;
    }
  }
  return null;
}

/// 克漏字 `{{答案}}`：答案至少一個字元，不含換行；`{`、`}` 只能在公式裡；不能跨進程式碼
export function clozeMatches(
  text: string,
  inCode: (offset: number) => boolean = () => false,
  math: MathSpan[] = mathSpans(text, inCode),
): ClozeMatch[] {
  const mathAt = new Map(math.map((m) => [m.from, m]));
  const inMath = (offset: number) => math.some((m) => offset >= m.from && offset < m.to);
  const result: ClozeMatch[] = [];
  let i = 0;
  while (i < text.length) {
    if (!text.startsWith("{{", i) || inCode(i) || inMath(i)) {
      i++;
      continue;
    }
    const start = i + 2;
    let end: number | null = null;
    for (let j = start; j < text.length; ) {
      const span = mathAt.get(j);
      if (span) {
        j = span.to;
        continue;
      }
      if (inCode(j) || text[j] === "\n" || text[j] === "{") break;
      if (text[j] === "}") {
        if (j > start && text[j + 1] === "}" && !inCode(j + 1)) end = j;
        break;
      }
      j++;
    }
    if (end === null) {
      i++;
      continue;
    }
    result.push({ from: i, to: end + 2, answer: text.slice(start, end) });
    i = end + 2;
  }
  return result;
}
