// Live Preview：游標所在行顯示 md 語法，其他行隱藏語法標記並套用樣式。
// 只處理可見範圍（view.visibleRanges），大檔案也不需要走訪全文。
import { syntaxTree } from "@codemirror/language";
import { EditorState, RangeSetBuilder } from "@codemirror/state";
import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from "@codemirror/view";

// 語法標記節點：非游標行時隱藏
const HIDDEN_MARKS = new Set([
  "HeaderMark",
  "EmphasisMark",
  "CodeMark",
  "LinkMark",
  "StrikethroughMark",
  "QuoteMark",
]);

const hide = Decoration.replace({});

class BulletWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = "cm-lp-bullet";
    span.textContent = "•";
    return span;
  }
}

class CheckboxWidget extends WidgetType {
  constructor(readonly checked: boolean, readonly pos: number) {
    super();
  }
  eq(other: CheckboxWidget) {
    return other.checked === this.checked && other.pos === this.pos;
  }
  toDOM(view: EditorView) {
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = this.checked;
    box.className = "cm-lp-task";
    box.addEventListener("mousedown", (e) => {
      e.preventDefault();
      view.dispatch({
        changes: { from: this.pos, to: this.pos + 3, insert: this.checked ? "[ ]" : "[x]" },
      });
    });
    return box;
  }
  ignoreEvent() {
    return false;
  }
}

// 游標（含多重選取）所在的行號集合
function activeLines(state: EditorState): Set<number> {
  const lines = new Set<number>();
  for (const r of state.selection.ranges) {
    const first = state.doc.lineAt(r.from).number;
    const last = state.doc.lineAt(r.to).number;
    for (let n = first; n <= last; n++) lines.add(n);
  }
  return lines;
}

const WIKILINK = /\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]/g;
// 與 Swift 端 MarkdownKind 的標籤規則一致
const TAG = /(?<![\p{L}\p{N}_#&\/])#([\p{L}\p{N}_\/-]+)/gu;

function inCode(state: EditorState, pos: number): boolean {
  for (let n: ReturnType<typeof syntaxTree>["topNode"] | null = syntaxTree(state).resolveInner(pos, 1); n; n = n.parent) {
    if (n.name === "InlineCode" || n.name === "FencedCode" || n.name === "CodeBlock") return true;
  }
  return false;
}

function build(view: EditorView): DecorationSet {
  const { state } = view;
  const active = view.hasFocus ? activeLines(state) : new Set<number>();
  const ranges: { from: number; to: number; deco: Decoration }[] = [];
  const isActive = (pos: number) => active.has(state.doc.lineAt(pos).number);

  for (const { from, to } of view.visibleRanges) {
    // [[wikilink]]：Lezer 不認得，會誤判成一般連結，所以先找出範圍，樹走訪時跳過
    const wikiRanges: [number, number][] = [];
    const text = state.doc.sliceString(from, to);
    for (const m of text.matchAll(WIKILINK)) {
      const start = from + m.index!;
      const end = start + m[0].length;
      wikiRanges.push([start, end]);
      const linkDeco = Decoration.mark({ class: "cm-lp-wikilink", attributes: { "data-target": m[1] } });
      if (isActive(start)) {
        ranges.push({ from: start, to: end, deco: linkDeco });
      } else {
        const labelStart = m[2] ? start + 2 + m[1].length + 1 : start + 2;
        ranges.push({ from: start, to: labelStart, deco: hide });
        ranges.push({ from: labelStart, to: end - 2, deco: linkDeco });
        ranges.push({ from: end - 2, to: end, deco: hide });
      }
    }
    for (const m of text.matchAll(TAG)) {
      const start = from + m.index!;
      if (inCode(state, start)) continue;
      ranges.push({
        from: start,
        to: start + m[0].length,
        deco: Decoration.mark({ class: "cm-lp-tag", attributes: { "data-tag": m[1] } }),
      });
    }
    const inWiki = (a: number, b: number) => wikiRanges.some(([s, e]) => a < e && b > s);

    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const name = node.name;
        if ((name === "Link" || name === "LinkMark" || name === "URL") && inWiki(node.from, node.to)) return false;
        const heading = /^ATXHeading(\d)$/.exec(name);
        if (heading) {
          const line = state.doc.lineAt(node.from);
          ranges.push({
            from: line.from,
            to: line.from,
            deco: Decoration.line({ class: `cm-lp-h cm-lp-h${heading[1]}` }),
          });
        }
        if (name === "Blockquote") {
          for (let p = node.from; p <= node.to; ) {
            const line = state.doc.lineAt(p);
            ranges.push({ from: line.from, to: line.from, deco: Decoration.line({ class: "cm-lp-quote" }) });
            p = line.to + 1;
          }
        }
        if (name === "FencedCode") {
          for (let p = node.from; p <= node.to; ) {
            const line = state.doc.lineAt(p);
            ranges.push({ from: line.from, to: line.from, deco: Decoration.line({ class: "cm-lp-codeblock" }) });
            p = line.to + 1;
          }
          const info = node.node.getChild("CodeInfo");
          if (info) ranges.push({ from: info.from, to: info.to, deco: Decoration.mark({ class: "cm-lp-codeinfo" }) });
          return false; // 程式碼區塊內不處理其他標記
        }
        if (name === "Emphasis") ranges.push({ from: node.from, to: node.to, deco: Decoration.mark({ class: "cm-lp-em" }) });
        if (name === "StrongEmphasis") ranges.push({ from: node.from, to: node.to, deco: Decoration.mark({ class: "cm-lp-strong" }) });
        if (name === "Strikethrough") ranges.push({ from: node.from, to: node.to, deco: Decoration.mark({ class: "cm-lp-strike" }) });
        if (name === "InlineCode") ranges.push({ from: node.from, to: node.to, deco: Decoration.mark({ class: "cm-lp-code" }) });

        if (isActive(node.from)) return;

        if (HIDDEN_MARKS.has(name)) {
          // 標題的 "# " 連同後面的空白一起隱藏
          let end = node.to;
          if ((name === "HeaderMark" || name === "QuoteMark") && state.doc.sliceString(end, end + 1) === " ") end++;
          ranges.push({ from: node.from, to: end, deco: hide });
        }
        if (name === "URL" && node.node.parent?.name === "Link") {
          ranges.push({ from: node.from, to: node.to, deco: hide });
        }
        if (name === "ListMark") {
          const text = state.doc.sliceString(node.from, node.to);
          const after = state.doc.sliceString(node.to + 1, node.to + 4);
          const isTask = /^\[[ xX]\]$/.test(after);
          if (isTask) {
            ranges.push({ from: node.from, to: node.to + 1, deco: hide });
            ranges.push({
              from: node.to + 1,
              to: node.to + 4,
              deco: Decoration.replace({ widget: new CheckboxWidget(after !== "[ ]", node.to + 1) }),
            });
          } else if (text === "-" || text === "*" || text === "+") {
            ranges.push({ from: node.from, to: node.to, deco: Decoration.replace({ widget: new BulletWidget() }) });
          }
        }
      },
    });

  }

  // RangeSetBuilder 需要依 from、startSide 排序；line decoration 的 startSide 最小
  ranges.sort((a, b) => a.from - b.from || a.deco.startSide - b.deco.startSide || a.to - b.to);
  const builder = new RangeSetBuilder<Decoration>();
  let lastReplaceEnd = -1;
  for (const r of ranges) {
    const isReplace = (r.deco.spec as { widget?: unknown }).widget !== undefined || r.deco === hide;
    // replace 範圍不可重疊
    if (isReplace && r.from < lastReplaceEnd) continue;
    builder.add(r.from, r.to, r.deco);
    if (isReplace) lastReplaceEnd = r.to;
  }
  return builder.finish();
}

export const livePreview = ViewPlugin.fromClass(
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
