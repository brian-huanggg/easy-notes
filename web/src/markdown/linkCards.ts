// 獨占一行的 `[[連結]]` 顯示為連結卡片（相鄰的多行並排），`![[圖片]]` 顯示為圖片。
// 游標所在行顯示原始 md。block decoration 不能由 ViewPlugin 提供，所以用 StateField；
// 只在文件、游標所在行或連結目標改變時重算。
import { syntaxTree } from "@codemirror/language";
import { EditorState, Extension, Range, StateEffect, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { el, onPress, post, relativeTime, vaultURL, withVerb } from "./bridge";

// Swift 推送的連結目標（App 從索引與 PluginRegistry 組出來，編輯器不認識其他外掛）
export interface LinkTarget {
  name: string;
  path: string;
  /// 類型圖示（PNG data URI，當 CSS mask 用）
  icon?: string;
  /// 類型顏色 [base 淺, base 深, soft 淺, soft 深]
  tint: [string, string, string, string];
  summary?: string;
  /// 毫秒
  modified: number;
}

let targets = new Map<string, LinkTarget>();
let targetsVersion = 0;
export const targetsChanged = StateEffect.define<null>();

export function setLinkTargets(view: EditorView, list: LinkTarget[]) {
  targets = new Map();
  for (const t of list) {
    const key = t.name.toLowerCase();
    if (!targets.has(key)) targets.set(key, t);
  }
  targetsVersion++;
  view.dispatch({ effects: targetsChanged.of(null) });
}

// `[[資料夾/名稱.md]]` → 「名稱」
function lookup(target: string): LinkTarget | undefined {
  const name = target.split("/").pop()!.replace(/\.md$/i, "").toLowerCase();
  return targets.get(name);
}

const CARD = /^\s*\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]\s*$/;
const IMAGE = /^\s*!\[\[([^\]|\n]+\.(?:png|jpe?g|gif|webp|heic|avif|svg))(?:\|[^\]\n]*)?\]\]\s*$/i;

interface Card {
  target: string;
  label: string;
}

const CHEVRON = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>';

class CardsWidget extends WidgetType {
  constructor(readonly cards: Card[], readonly version: number, readonly firstLine: number) {
    super();
  }
  eq(other: CardsWidget) {
    return (
      other.version === this.version &&
      other.firstLine === this.firstLine &&
      other.cards.length === this.cards.length &&
      other.cards.every((c, i) => c.target === this.cards[i].target && c.label === this.cards[i].label)
    );
  }
  toDOM(view: EditorView) {
    const grid = el("div", "cm-lp-cards");
    this.cards.forEach((card, i) => {
      const t = lookup(card.target);
      const node = el("div", "cm-lp-card");
      const icon = el("span", "cm-lp-card-icon");
      const glyph = el("i");
      if (t) {
        node.style.setProperty("--tint", `light-dark(${t.tint[0]}, ${t.tint[1]})`);
        node.style.setProperty("--tint-soft", `light-dark(${t.tint[2]}, ${t.tint[3]})`);
        if (t.icon) glyph.style.setProperty("--icon", `url("${t.icon}")`);
      } else {
        node.classList.add("is-missing");
      }
      icon.append(glyph);
      const text = el("span", "cm-lp-card-text");
      text.append(el("span", "cm-lp-card-title", card.label));
      const sub = t ? [t.summary, withVerb(relativeTime(t.modified), "更新")].filter(Boolean).join(" · ") : "點一下建立新筆記";
      text.append(el("span", "cm-lp-card-sub", sub));
      const chevron = el("span", "cm-lp-card-chevron");
      chevron.innerHTML = CHEVRON;
      node.append(icon, text, chevron);
      onPress(node, (e) => {
        // ⌘ / ⌥ 點擊：把游標放進那一行，顯示原始 md
        if (e.metaKey || e.altKey) {
          const line = view.state.doc.line(this.firstLine + i);
          view.dispatch({ selection: { anchor: line.to } });
          view.focus();
        } else {
          post({ type: "openLink", target: card.target });
        }
      });
      grid.append(node);
    });
    return grid;
  }
  ignoreEvent() {
    return true;
  }
}

class ImageWidget extends WidgetType {
  constructor(readonly path: string) {
    super();
  }
  eq(other: ImageWidget) {
    return other.path === this.path;
  }
  toDOM() {
    const box = el("div", "cm-lp-embed");
    const img = el("img");
    img.src = vaultURL(this.path);
    img.alt = this.path;
    img.addEventListener("error", () => box.classList.add("is-missing"));
    box.append(img);
    return box;
  }
  get estimatedHeight() {
    return 240;
  }
}

function inCode(state: EditorState, pos: number): boolean {
  for (let n: ReturnType<typeof syntaxTree>["topNode"] | null = syntaxTree(state).resolveInner(pos, 1); n; n = n.parent) {
    if (n.name === "FencedCode" || n.name === "CodeBlock") return true;
  }
  return false;
}

function activeLines(state: EditorState): Set<number> {
  const lines = new Set<number>();
  for (const r of state.selection.ranges) {
    const last = state.doc.lineAt(r.to).number;
    for (let n = state.doc.lineAt(r.from).number; n <= last; n++) lines.add(n);
  }
  return lines;
}

interface Value {
  decos: DecorationSet;
  active: string;
}

function build(state: EditorState, active: Set<number>): DecorationSet {
  const decos: Range<Decoration>[] = [];
  const { doc } = state;
  let group: { first: number; cards: Card[] } | null = null;
  const flush = () => {
    if (!group) return;
    const from = doc.line(group.first).from;
    const to = doc.line(group.first + group.cards.length - 1).to;
    decos.push(Decoration.replace({ widget: new CardsWidget(group.cards, targetsVersion, group.first), block: true }).range(from, to));
    group = null;
  };

  for (let n = 1; n <= doc.lines; n++) {
    const line = doc.line(n);
    const head = line.text.trimStart();
    if (!head.startsWith("[[") && !head.startsWith("![[")) {
      flush();
      continue;
    }
    if (active.has(n) || inCode(state, line.from)) {
      flush();
      continue;
    }
    const card = CARD.exec(line.text);
    if (card) {
      const target = card[1].trim();
      if (group && group.first + group.cards.length === n) group.cards.push({ target, label: card[2]?.trim() || target });
      else {
        flush();
        group = { first: n, cards: [{ target, label: card[2]?.trim() || target }] };
      }
      continue;
    }
    flush();
    const image = IMAGE.exec(line.text);
    if (image) {
      // 沒有資料夾的檔名視為在附件資料夾
      const path = image[1].includes("/") ? image[1] : `附件/${image[1]}`;
      decos.push(Decoration.replace({ widget: new ImageWidget(path), block: true }).range(line.from, line.to));
    }
  }
  flush();
  return Decoration.set(decos);
}

const field = StateField.define<Value>({
  create(state) {
    const active = activeLines(state);
    return { decos: build(state, active), active: [...active].join(",") };
  },
  update(value, tr) {
    const active = activeLines(tr.state);
    const key = [...active].join(",");
    if (tr.docChanged || key !== value.active || tr.effects.some((e) => e.is(targetsChanged))) {
      return { decos: build(tr.state, active), active: key };
    }
    return value;
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.decos),
});

export const linkCards: Extension = field;
