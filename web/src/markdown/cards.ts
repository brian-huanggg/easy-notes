// 卡片語法標示（Vault 的 Markdown 方言）。規則與 Swift 端 Flashcards 的 CardSyntax 一致：
//   `問 :: 答` 正向、`中文 ;; English` 雙向、`{{答案}}` 克漏字、行尾 `^id` 是卡片的身分
//   `::`、`;;` 前後要有空白；程式碼與 frontmatter 內不算
// 游標所在行顯示原始語法（`^id` 淡化）；其他行 `::` / `;;` 換成箭頭、克漏字隱藏括號、`^id` 隱藏。
// 只標示，不改內容：`^id` 由 App 在離開檔案後補上，打字與注音組字中不會插入文字。
import { RangeSetBuilder } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import { t } from "../shared/i18n";
import { frontmatterRange } from "./docHeader";
import { activeLines, inCode } from "./livePreview";

const BLOCK_ID = /\s\^([A-Za-z0-9-]+)\s*$/;
const LINE_PREFIX = /^\s*(?:>\s?)*\s*(?:#{1,6}\s+|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?/;
const CLOZE = /\{\{([^{}\n]+?)\}\}/g;
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

function build(view: EditorView): DecorationSet {
  const { state } = view;
  const active = view.hasFocus ? activeLines(state) : new Set<number>();
  const fm = frontmatterRange(state);
  const ranges: { from: number; to: number; deco: Decoration }[] = [];

  for (const { from, to } of view.visibleRanges) {
    for (let pos = from; pos <= to; ) {
      const line = state.doc.lineAt(pos);
      pos = line.to + 1;
      if (fm && line.from <= fm.to) continue;
      if (!line.text.trim() || inCode(state, line.from)) continue;

      const text = line.text;
      const idMatch = BLOCK_ID.exec(text);
      const contentEnd = idMatch ? idMatch.index : text.replace(/\s+$/, "").length;
      const start = LINE_PREFIX.exec(text.slice(0, contentEnd))?.[0].length ?? 0;
      const body = text.slice(start, contentEnd);
      const isActive = active.has(line.number);
      const at = (offset: number) => line.from + start + offset;
      const card: typeof ranges = [];

      const clozes = [...body.matchAll(CLOZE)].filter((m) => !inCode(state, at(m.index!)));
      if (clozes.length > 0) {
        if (clozes.some((m) => !m[1].trim())) continue;
        for (const m of clozes) {
          const open = at(m.index!);
          const close = open + m[0].length - 2;
          card.push({ from: open, to: open + 2, deco: isActive ? braceMark : hide });
          card.push({ from: open + 2, to: close, deco: clozeMark });
          card.push({ from: close, to: close + 2, deco: isActive ? braceMark : hide });
        }
      } else {
        const sep = [...body.matchAll(SEPARATOR)].find((m) => !inCode(state, at(m.index! + 1)));
        if (!sep) continue;
        const sepFrom = sep.index! + 1;
        if (!body.slice(0, sepFrom).trim() || !body.slice(sepFrom + 2).trim()) continue;
        const deco = isActive ? sepMark : sep[1] === ";;" ? bidirectionalWidget : forwardWidget;
        card.push({ from: at(sepFrom), to: at(sepFrom + 2), deco });
      }

      if (idMatch) {
        const caret = line.from + idMatch.index + idMatch[0].indexOf("^");
        const idEnd = caret + 1 + idMatch[1].length;
        card.push(isActive ? { from: caret, to: idEnd, deco: idMark } : { from: line.from + idMatch.index, to: idEnd, deco: hide });
      }
      ranges.push(...card);
    }
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
