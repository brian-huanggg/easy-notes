// frontmatter（檔案開頭的 `---` YAML 區塊）：游標不在區塊內時收合成一行屬性，點一下展開原始 YAML。
// 判斷規則與 Swift 端 KindMarkdown/Frontmatter.swift 一致：第一行是 `---`，之後第一個獨占一行的 `---` 結束。
// 2.5d 會換成封面、icon、標題、meta 的文件頭。
import { EditorState, Extension, Range, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";

// frontmatter 的範圍：第一行開頭到結尾 `---` 那一行的行尾；沒有時回傳 null
export function frontmatterRange(state: EditorState): { from: number; to: number } | null {
  const doc = state.doc;
  if (doc.lines < 2 || doc.line(1).text !== "---") return null;
  for (let n = 2; n <= doc.lines; n++) {
    if (doc.line(n).text === "---") {
      return { from: 0, to: doc.line(n).to };
    }
  }
  return null;
}

function properties(yaml: string): string[] {
  const pills: string[] = [];
  let others = 0;
  for (const line of yaml.split("\n")) {
    const m = /^([A-Za-z_][\w-]*)\s*:\s*(.*)$/.exec(line);
    if (!m) continue;
    const [, key, raw] = m;
    const value = raw.replace(/\s+#.*$/, "").replace(/^["']|["']$/g, "").trim();
    if (key === "pinned") {
      if (/^(true|yes|on)$/i.test(value)) pills.push("📌 已釘選");
    } else if (key === "icon" && value) {
      pills.unshift(value);
    } else if (key === "tags") {
      const tags = value.replace(/^\[|\]$/g, "").split(",").map((t) => t.trim()).filter(Boolean);
      if (tags.length) pills.push(tags.map((t) => "#" + t).join(" "));
      else others++;
    } else {
      others++;
    }
  }
  if (others) pills.push(`${others} 個屬性`);
  return pills;
}

class PropertiesWidget extends WidgetType {
  constructor(readonly pills: string[]) {
    super();
  }
  eq(other: PropertiesWidget) {
    return other.pills.join("\n") === this.pills.join("\n");
  }
  toDOM(view: EditorView) {
    const row = document.createElement("div");
    row.className = "cm-lp-frontmatter";
    row.title = "顯示屬性（YAML）";
    for (const text of this.pills.length ? this.pills : ["屬性"]) {
      const pill = document.createElement("span");
      pill.textContent = text;
      row.appendChild(pill);
    }
    row.addEventListener("mousedown", (e) => {
      e.preventDefault();
      view.dispatch({ selection: { anchor: 4 } });
      view.focus();
    });
    return row;
  }
  ignoreEvent() {
    return false;
  }
}

function build(state: EditorState): DecorationSet {
  const range = frontmatterRange(state);
  if (!range) return Decoration.none;
  const inside = state.selection.ranges.some((r) => r.from <= range.to);
  if (inside) {
    const decos: Range<Decoration>[] = [];
    for (let pos = range.from; pos <= range.to; ) {
      const line = state.doc.lineAt(pos);
      decos.push(Decoration.line({ class: "cm-lp-yaml" }).range(line.from));
      pos = line.to + 1;
    }
    return Decoration.set(decos);
  }
  const yaml = state.doc.sliceString(state.doc.line(1).to + 1, state.doc.lineAt(range.to).from);
  return Decoration.set([
    Decoration.replace({ widget: new PropertiesWidget(properties(yaml)), block: true }).range(range.from, range.to),
  ]);
}

export const frontmatter: Extension = StateField.define<DecorationSet>({
  create: build,
  update(value, tr) {
    return tr.docChanged || tr.selection ? build(tr.state) : value;
  },
  provide: (f) => EditorView.decorations.from(f),
});
