// 卡片語法標示（Vault 的 Markdown 方言）。規則與 Swift 端 Flashcards 的 CardSyntax 一致：
//   `問 :: 答` 正向、`中文 ;; English` 雙向、`{{答案}}` 克漏字、行尾 `^id` 是卡片的身分
//   `::`、`;;` 前後要有空白；程式碼、公式（`$…$`）與 frontmatter 內不算
//   清單項目以 ` ::` / ` ;;` 結尾 = 多行 note：子行中只有 `::` 的行是正反面的分界，克漏字標示到分界行為止
// 游標所在行顯示原始語法（`^id` 淡化）；其他行 `::` / `;;` 換成箭頭、克漏字隱藏括號、`^id` 隱藏。
// 只標示，不改內容：`^id` 由 App 在離開檔案後補上，打字與注音組字中不會插入文字。
import { syntaxTree } from "@codemirror/language";
import { EditorState, RangeSetBuilder } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import { t } from "../shared/i18n";
import { frontmatterRange } from "./docHeader";
import { blockEnd, blockHead, clozeMatches, isDivider, mathSpans } from "./cardSyntax";
import { activeLines, inCode } from "./livePreview";

const BLOCK_ID = /\s\^([A-Za-z0-9-]+)\s*$/;
const LINE_PREFIX = /^\s*(?:>\s?)*\s*(?:#{1,6}\s+|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?/;
const SEPARATOR = /\s(::|;;)(?=\s)/g;

class SeparatorWidget extends WidgetType {
  constructor(readonly bidirectional: boolean) {
    super();
  }
  eq(other: SeparatorWidget) {
    return other.bidirectional === this.bidirectional;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-card-sep";
    span.textContent = this.bidirectional ? "⇄" : "→";
    span.title = this.bidirectional ? t("雙向卡片") : t("卡片");
    return span;
  }
}

const hide = Decoration.replace({});
const sepMark = Decoration.mark({ class: "cm-card-sep" });
const clozeMark = Decoration.mark({ class: "cm-card-cloze" });
const braceMark = Decoration.mark({ class: "cm-card-brace" });
const idMark = Decoration.mark({ class: "cm-card-id" });
const forwardWidget = Decoration.replace({ widget: new SeparatorWidget(false) });
const bidirectionalWidget = Decoration.replace({ widget: new SeparatorWidget(true) });

/// 一行中行內程式碼的範圍（文件位置）；每個字元都查語法樹太慢，所以一行查一次
function inlineCode(state: EditorState, from: number, to: number): { from: number; to: number }[] {
  const ranges: { from: number; to: number }[] = [];
  syntaxTree(state).iterate({
    from,
    to,
    enter: (n) => {
      if (n.name !== "InlineCode") return;
      ranges.push({ from: n.from, to: n.to });
      return false;
    },
  });
  return ranges;
}

type Range = { from: number; to: number; deco: Decoration };

/// 行內程式碼的判斷（行內 offset → 是否在程式碼中）
function codeChecker(state: EditorState, from: number, to: number): (lineOffset: number) => boolean {
  const code = inlineCode(state, from, to);
  return (offset) => code.some((r) => from + offset >= r.from && from + offset < r.to);
}

/// 一段文字（行內 offset `start` 起）中的克漏字；有空的答案時回傳 null
function clozeDecos(text: string, start: number, lineFrom: number, codeAt: (o: number) => boolean, active: boolean): Range[] | null {
  const body = text.slice(start);
  const at = (offset: number) => lineFrom + start + offset;
  const bodyCode = (o: number) => codeAt(start + o);
  const math = body.includes("$") ? mathSpans(body, bodyCode) : [];
  const clozes = clozeMatches(body, bodyCode, math);
  if (clozes.some((m) => !m.answer.trim())) return null;
  return clozes.flatMap((m) => {
    const open = at(m.from);
    const close = at(m.to) - 2;
    return [
      { from: open, to: open + 2, deco: active ? braceMark : hide },
      { from: open + 2, to: close, deco: clozeMark },
      { from: close, to: close + 2, deco: active ? braceMark : hide },
    ];
  });
}

/// 首行行尾的 `^id`：游標所在行淡化，其他行隱藏
function idDeco(text: string, lineFrom: number, active: boolean): Range[] {
  const idMatch = BLOCK_ID.exec(text);
  if (!idMatch) return [];
  const caret = lineFrom + idMatch.index + idMatch[0].indexOf("^");
  const idEnd = caret + 1 + idMatch[1].length;
  return [active ? { from: caret, to: idEnd, deco: idMark } : { from: lineFrom + idMatch.index, to: idEnd, deco: hide }];
}

const separatorDeco = (from: number, bidirectional: boolean, active: boolean): Range => ({
  from,
  to: from + 2,
  deco: active ? sepMark : bidirectional ? bidirectionalWidget : forwardWidget,
});

/// 單行 note
function singleLine(state: EditorState, line: { from: number; text: string }, active: boolean): Range[] {
  const text = line.text;
  const idMatch = BLOCK_ID.exec(text);
  const contentEnd = idMatch ? idMatch.index : text.replace(/\s+$/, "").length;
  const start = LINE_PREFIX.exec(text.slice(0, contentEnd))?.[0].length ?? 0;
  const body = text.slice(start, contentEnd);
  const codeAt = codeChecker(state, line.from, line.from + contentEnd);
  const clozes = clozeDecos(text.slice(0, contentEnd), start, line.from, codeAt, active);
  if (clozes === null) return [];
  const card: Range[] = clozes;
  if (clozes.length === 0) {
    const bodyCode = (o: number) => codeAt(start + o);
    const math = body.includes("$") ? mathSpans(body, bodyCode) : [];
    const inMath = (offset: number) => math.some((m) => offset >= m.from && offset < m.to);
    const sep = [...body.matchAll(SEPARATOR)].find((m) => !bodyCode(m.index! + 1) && !inMath(m.index! + 1));
    if (!sep) return [];
    const sepFrom = sep.index! + 1;
    if (!body.slice(0, sepFrom).trim() || !body.slice(sepFrom + 2).trim()) return [];
    card.push(separatorDeco(line.from + start + sepFrom, sep[1] === ";;", active));
  }
  return [...card, ...idDeco(text, line.from, active)];
}

function build(view: EditorView): DecorationSet {
  const { state } = view;
  const { doc } = state;
  const active = view.hasFocus ? activeLines(state) : new Set<number>();
  const fm = frontmatterRange(state);
  const ranges: Range[] = [];
  const textAt = (n: number) => (n <= doc.lines ? doc.line(n).text : null);
  const skip = (line: { from: number; text: string }) =>
    (fm !== null && line.from <= fm.to) || !line.text.trim() || inCode(state, line.from);
  let done = 0;

  for (const { from, to } of view.visibleRanges) {
    const first = doc.lineAt(from).number;
    const last = doc.lineAt(to).number;
    // 子行要知道自己屬於哪一筆多行 note：從上方最近一個沒有縮排的行開始解析（最多往回 500 行）
    let n = first;
    while (n > 1 && first - n < 500 && /^(\s|$)/.test(doc.line(n).text)) n--;
    n = Math.max(n, done + 1);
    while (n <= last) {
      const line = doc.line(n);
      const visible = n >= first;
      if (skip(line)) {
        n++;
        continue;
      }
      const head = blockHead(line.text, codeChecker(state, line.from, line.to));
      const end = head ? blockEnd(textAt, n, head.column) : n;
      if (head && end > n) {
        const isActive = active.has(n);
        if (visible) ranges.push(separatorDeco(line.from + head.sepFrom, head.bidirectional, isActive), ...idDeco(line.text, line.from, isActive));
        // 子行：分界行之前的克漏字、分界行本身；子行中的卡片語法不另外成為卡片
        let divided = false;
        for (let c = n + 1; c <= end; c++) {
          const child = doc.line(c);
          if (!child.text.trim() || inCode(state, child.from)) continue;
          const childActive = active.has(c);
          if (!divided && isDivider(child.text)) {
            divided = true;
            const at = child.from + child.text.indexOf(child.text.trim());
            if (c >= first) ranges.push(separatorDeco(at, head.bidirectional, childActive));
            continue;
          }
          if (divided || c < first) continue;
          const clozes = clozeDecos(child.text, 0, child.from, codeChecker(state, child.from, child.to), childActive);
          if (clozes) ranges.push(...clozes);
        }
        n = end + 1;
        continue;
      }
      if (visible) ranges.push(...singleLine(state, line, active.has(n)));
      n++;
    }
    done = last;
  }

  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  const builder = new RangeSetBuilder<Decoration>();
  for (const r of ranges) builder.add(r.from, r.to, r.deco);
  return builder.finish();
}

export const cards = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = build(view);
    }
    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.selectionSet || u.focusChanged) {
        this.decorations = build(u.view);
      }
    }
  },
  { decorations: (v) => v.decorations },
);
