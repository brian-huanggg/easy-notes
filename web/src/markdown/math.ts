// 數學公式（LaTeX）：`$…$` 行內、`$$…$$` 區塊，以 KaTeX 渲染。
// 語法擴充 Lezer markdown：公式內不再解析粗體、標籤等標記。規則（與 Pandoc 相同）：
// 行內的開頭 `$` 後面不能是空白、結尾 `$` 前面不能是空白、後面不能是數字，所以「$5 和 $10」不是公式。
// 區塊從 `$$` 開頭的行到 `$$` 結尾的行；還沒打結尾時到空行為止（TeX 的公式內不能有空行）。
// KaTeX（約 270 KB + 字型）只在文件第一次出現公式時才載入（katex/，build.mjs 從 node_modules 複製），
// 載入前顯示原始碼。行內公式由 livePreview 換成 widget；區塊公式是 block decoration，在這裡用 StateField。
import { syntaxTree } from "@codemirror/language";
import { EditorState, Extension, Range, StateEffect, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { editingRange, setEditorFocus } from "./editorFocus";
import { tags } from "@lezer/highlight";
import type { BlockContext, Line, MarkdownConfig } from "@lezer/markdown";

const DOLLAR = 36;
const BACKSLASH = 92;
const isSpace = (ch: number) => ch === 32 || ch === 9 || ch === 10;

export const mathSyntax: MarkdownConfig = {
  defineNodes: [{ name: "InlineMath" }, { name: "BlockMath", block: true }, { name: "MathMark", style: tags.processingInstruction }],
  parseInline: [
    {
      name: "InlineMath",
      before: "Emphasis",
      parse(cx, next, pos) {
        if (next !== DOLLAR) return -1;
        const double = cx.char(pos + 1) === DOLLAR;
        const start = pos + (double ? 2 : 1);
        if (start >= cx.end) return -1;
        if (!double && (isSpace(cx.char(start)) || cx.char(start) === DOLLAR)) return -1;
        for (let i = start + 1; i < cx.end; i++) {
          const ch = cx.char(i);
          if (ch === BACKSLASH) {
            i++;
            continue;
          }
          if (ch !== DOLLAR) continue;
          if (double) {
            if (cx.char(i + 1) !== DOLLAR) continue;
            return cx.addElement(cx.elt("InlineMath", pos, i + 2, [cx.elt("MathMark", pos, start), cx.elt("MathMark", i, i + 2)]));
          }
          if (isSpace(cx.char(i - 1))) continue;
          const after = cx.char(i + 1);
          if (after >= 48 && after <= 57) continue;
          return cx.addElement(cx.elt("InlineMath", pos, i + 1, [cx.elt("MathMark", pos, start), cx.elt("MathMark", i, i + 1)]));
        }
        return -1;
      },
    },
  ],
  parseBlock: [
    {
      name: "BlockMath",
      before: "FencedCode",
      parse(cx: BlockContext, line: Line) {
        if (line.indent - line.baseIndent >= 4 || !line.text.startsWith("$$", line.pos)) return false;
        const from = cx.lineStart + line.pos;
        const rest = line.text.slice(line.pos + 2).trimEnd();
        // 同一行結束：`$$ x^2 $$`
        if (rest.length >= 2 && rest.endsWith("$$")) {
          const end = from + 2 + rest.length;
          cx.addElement(cx.elt("BlockMath", from, end, [cx.elt("MathMark", from, from + 2), cx.elt("MathMark", end - 2, end)]));
          cx.nextLine();
          return true;
        }
        if (rest.includes("$$")) return false;
        // 還沒打結尾的 `$$` 時到空行或文件結尾為止（Lezer 不能回頭，無法改判成段落）
        const marks = [cx.elt("MathMark", from, from + 2)];
        let end = cx.lineStart + line.text.length;
        while (cx.nextLine()) {
          const text = line.text.trimEnd();
          if (text.trim() === "") break;
          end = cx.lineStart + text.length;
          if (text.endsWith("$$")) {
            marks.push(cx.elt("MathMark", end - 2, end));
            cx.nextLine();
            break;
          }
        }
        cx.addElement(cx.elt("BlockMath", from, end, marks));
        return true;
      },
    },
  ],
};

// MARK: KaTeX

interface Katex {
  renderToString(tex: string, options: { displayMode: boolean; throwOnError: boolean }): string;
}

declare global {
  interface Window {
    katex?: Katex;
  }
}

let katex: Katex | null = null;
let loading = false;
const readyListeners: (() => void)[] = [];

export function onMathReady(listener: () => void) {
  readyListeners.push(listener);
}

function loadKatex() {
  if (katex || loading || typeof document === "undefined") return;
  loading = true;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "katex/katex.min.css";
  document.head.append(link);
  const script = document.createElement("script");
  script.src = "katex/katex.min.js";
  script.onload = () => {
    katex = window.katex ?? null;
    for (const listener of readyListeners) listener();
  };
  script.onerror = () => (loading = false);
  document.head.append(script);
}

// 同一段公式只渲染一次（捲動、游標移動時 widget 會重建）
const cache = new Map<string, string>();

// KaTeX 的 HTML；還沒載入時回傳 null 並開始載入
export function mathHTML(tex: string, display: boolean): string | null {
  if (!katex) {
    loadKatex();
    return null;
  }
  const key = (display ? "D" : "I") + tex;
  let html = cache.get(key);
  if (html === undefined) {
    html = katex.renderToString(tex, { displayMode: display, throwOnError: false });
    if (cache.size > 500) cache.clear();
    cache.set(key, html);
  }
  return html;
}

export function mathIsReady(): boolean {
  return katex !== null;
}

function renderMath(node: HTMLElement, tex: string, display: boolean) {
  const html = mathHTML(tex, display);
  if (html === null) {
    node.textContent = tex;
    node.classList.add("is-loading");
  } else {
    node.innerHTML = html;
  }
}

export const mathLoaded = StateEffect.define<null>();

export class MathWidget extends WidgetType {
  constructor(readonly tex: string, readonly display: boolean, readonly ready = katex !== null) {
    super();
  }
  eq(other: MathWidget) {
    return other.tex === this.tex && other.display === this.display && other.ready === this.ready;
  }
  toDOM() {
    const node = document.createElement(this.display ? "div" : "span");
    node.className = this.display ? "cm-math cm-math-block" : "cm-math";
    renderMath(node, this.tex, this.display);
    return node;
  }
  // 點一下：CodeMirror 把游標放到公式旁邊，該行（區塊）改顯示原始碼
  ignoreEvent() {
    return false;
  }
}

// `$x$`、`$$x$$` → x
export function mathSource(text: string): { tex: string; display: boolean } {
  const display = text.startsWith("$$");
  const n = display ? 2 : 1;
  return { tex: text.slice(n, text.endsWith(display ? "$$" : "$") && text.length >= 2 * n ? -n : undefined).trim(), display };
}

// MARK: 區塊公式

const sourceLine = Decoration.line({ class: "cm-lp-math-src" });

function build(state: EditorState): DecorationSet {
  const decos: Range<Decoration>[] = [];
  const tree = syntaxTree(state);
  for (let node = tree.topNode.firstChild; node; node = node.nextSibling) {
    if (node.name !== "BlockMath") continue;
    const from = state.doc.lineAt(node.from).from;
    const to = state.doc.lineAt(node.to).to;
    const { tex } = mathSource(state.sliceDoc(node.from, node.to));
    const editing = editingRange(state, from, to);
    if (editing) {
      // 游標在公式內：顯示原始碼，下方即時預覽
      for (let pos = from; pos <= to; ) {
        const line = state.doc.lineAt(pos);
        decos.push(sourceLine.range(line.from));
        pos = line.to + 1;
      }
      if (tex) decos.push(Decoration.widget({ widget: new MathWidget(tex, true), block: true, side: 1 }).range(to));
    } else {
      decos.push(Decoration.replace({ widget: new MathWidget(tex, true), block: true }).range(from, to));
    }
  }
  return Decoration.set(decos, true);
}

const blockMathField = StateField.define<DecorationSet>({
  create: build,
  update(value, tr) {
    if (tr.docChanged || tr.selection || syntaxTree(tr.state) !== syntaxTree(tr.startState) || tr.effects.some((e) => e.is(mathLoaded) || e.is(setEditorFocus))) return build(tr.state);
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

export const blockMath: Extension = blockMathField;
