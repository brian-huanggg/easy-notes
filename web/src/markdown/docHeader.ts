// 文件頭：frontmatter（檔案開頭的 `---` YAML 區塊）顯示為封面、icon，第一行 `# 標題` 顯示為大標題，
// 標題下方是 meta 列（標籤、最後編輯時間）。游標進入 frontmatter 時才顯示原始 YAML。
// frontmatter 的判斷與寫入規則與 Swift 端 KindMarkdown/Frontmatter.swift 一致：
// 第一行是 `---`，之後第一個獨占一行的 `---` 結束；寫入只改動目標那一行，其餘位元組不變。
import { EditorState, Extension, Range, StateEffect, StateField, Text } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { t } from "../shared/i18n";
import { editedLabel, el, onPress, post, vaultURL } from "./bridge";
import { lines as textLines } from "./lineBreak";

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

// 兩條 `---` 之間的各行
function yamlLines(state: EditorState, range: { to: number }): string[] {
  const from = state.doc.line(1).to + 1;
  const to = state.doc.lineAt(range.to).from - 1;
  return to > from ? state.doc.sliceString(from, to).split("\n") : [];
}

function lineIndex(lines: string[], key: string): number {
  return lines.findIndex((line) => line.startsWith(key) && line.slice(key.length).trimStart().startsWith(":"));
}

function unquote(value: string): string {
  for (const q of ['"', "'"]) {
    if (value.length >= 2 && value.startsWith(q) && value.endsWith(q)) return value.slice(1, -1);
  }
  return value;
}

function scalarValue(line: string): string {
  let value = line.slice(line.indexOf(":") + 1).trim();
  // 行尾註解（不在引號內的 ` #`）
  if (!value.startsWith('"') && !value.startsWith("'")) {
    const hash = value.indexOf(" #");
    if (hash >= 0) value = value.slice(0, hash).trim();
  }
  return value;
}

interface Fields {
  icon?: string;
  cover?: string;
  tags: string[];
}

function readFields(lines: string[]): Fields {
  const scalar = (key: string) => {
    const i = lineIndex(lines, key);
    if (i < 0) return undefined;
    const value = scalarValue(lines[i]);
    return value ? unquote(value) : undefined;
  };
  // `tags: [a, b]`、`tags: a` 或下一行起的 `- a` 清單
  const tags: string[] = [];
  const i = lineIndex(lines, "tags");
  if (i >= 0) {
    const value = scalarValue(lines[i]);
    if (value.startsWith("[") && value.endsWith("]")) {
      tags.push(...value.slice(1, -1).split(",").map((t) => unquote(t.trim())));
    } else if (value) {
      tags.push(unquote(value));
    } else {
      for (const line of lines.slice(i + 1)) {
        const t = line.trim();
        if (!t.startsWith("- ")) break;
        tags.push(unquote(t.slice(2).trim()));
      }
    }
  }
  return { icon: scalar("icon"), cover: scalar("cover"), tags: tags.filter(Boolean) };
}

// YAML 純量：一般文字直接寫，含特殊字元時用雙引號
function yamlScalar(value: string): string {
  return /^[^\s\-?:,\[\]{}#&*!|>'"%@`][^:#\n]*$/.test(value) && value === value.trim() ? value : JSON.stringify(value);
}

// 設定（value 非 null）或移除頂層欄位的變更。沒有 frontmatter 時新增一個；移除後 frontmatter 變空就整個刪掉，
// 讓「設定再移除」回到原本的位元組。沒有要改的時候回傳 null。
export function frontmatterChange(state: EditorState, key: string, value: string | null): { from: number; to: number; insert: Text } | null {
  const range = frontmatterRange(state);
  const lines = range ? yamlLines(state, range) : [];
  const i = lineIndex(lines, key);
  if (i >= 0) {
    if (value === null) lines.splice(i, 1);
    else lines[i] = `${key}: ${yamlScalar(value)}`;
  } else if (value !== null) {
    lines.push(`${key}: ${yamlScalar(value)}`);
  } else {
    return null;
  }
  const to = range ? Math.min(range.to + 1, state.doc.length) : 0;
  const insert = textLines(lines.length ? `---\n${lines.join("\n")}\n---\n` : "");
  return { from: 0, to, insert };
}

// 以一般的編輯送出：可以 undo，並照常在停止輸入後寫回檔案
export function setFrontmatterField(view: EditorView, key: string, value: string | null) {
  const changes = frontmatterChange(view.state, key, value);
  if (changes) view.dispatch({ changes });
}

// 最後編輯時間（毫秒）：由 Swift 在開檔、外部修改時提供，存檔時更新
export const setModified = StateEffect.define<number | null>();

const modifiedField = StateField.define<number | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setModified)) value = e.value;
    return value;
  },
});

const ICON_IMAGE = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21"/></svg>';
const ICON_SMILE = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/><path d="M9 9h.01M15 9h.01"/></svg>';

function headerButton(svg: string, label: string, handler: () => void): HTMLElement {
  const button = el("span", "cm-doc-btn");
  button.innerHTML = svg;
  button.append(label);
  onPress(button, handler);
  return button;
}

class HeaderWidget extends WidgetType {
  constructor(readonly cover: string | undefined, readonly icon: string | undefined) {
    super();
  }
  eq(other: HeaderWidget) {
    return other.cover === this.cover && other.icon === this.icon;
  }
  toDOM() {
    const { cover, icon } = this;
    const root = el("div", "cm-doc-header");
    root.classList.toggle("has-cover", !!cover);
    root.classList.toggle("has-icon", !!icon);
    const pickCover = () => post({ type: "pickCover", hasCover: !!cover });
    const pickIcon = () => post({ type: "pickIcon", icon: icon ?? null });

    if (cover) {
      const box = el("div", "cm-doc-cover");
      const img = el("img");
      img.src = vaultURL(cover);
      img.alt = "";
      img.draggable = false;
      img.addEventListener("error", () => box.classList.add("is-missing"));
      const tools = el("div", "cm-doc-cover-tools");
      tools.append(headerButton(ICON_IMAGE, t("更換封面"), pickCover), headerButton(ICON_SMILE, icon ? t("更換圖示") : t("新增圖示"), pickIcon));
      box.append(img, tools);
      root.append(box);
    } else {
      // 沒有封面：游標移到文件頭時才出現的新增按鈕
      const add = el("div", "cm-doc-add");
      add.append(headerButton(ICON_IMAGE, t("新增封面"), pickCover));
      if (!icon) add.append(headerButton(ICON_SMILE, t("新增圖示"), pickIcon));
      root.append(add);
    }
    if (icon) {
      // `sf:map` = SF Symbol（Swift 端的 symbol:// 畫成 PNG，這裡當 mask 上色）；其他 = emoji
      const badge = el("div", "cm-doc-icon");
      if (icon.startsWith("sf:")) {
        const glyph = el("i", "cm-doc-icon-symbol");
        glyph.style.setProperty("--icon", `url("symbol:///${encodeURIComponent(icon.slice(3))}")`);
        badge.append(glyph);
      } else {
        badge.textContent = icon;
      }
      badge.title = t("更換圖示");
      onPress(badge, pickIcon);
      root.append(badge);
    }
    return root;
  }
  ignoreEvent() {
    return true;
  }
}

// 標籤色點：依名稱固定取一個顏色
const TAG_COLORS = ["--accent", "--yellow", "--card-due", "--card-learn", "--type-board"];

function tagColor(tag: string): string {
  let h = 0;
  for (const ch of tag) h = (h * 31 + ch.codePointAt(0)!) >>> 0;
  return `var(${TAG_COLORS[h % TAG_COLORS.length]}, var(--accent))`;
}

class MetaWidget extends WidgetType {
  constructor(readonly tags: string[], readonly edited: string | null) {
    super();
  }
  eq(other: MetaWidget) {
    return other.edited === this.edited && other.tags.join("\n") === this.tags.join("\n");
  }
  toDOM() {
    const row = el("div", "cm-doc-meta");
    for (const tag of this.tags) {
      const pill = el("span", "cm-doc-tag");
      const dot = el("i");
      dot.style.background = tagColor(tag);
      pill.append(dot, tag);
      onPress(pill, () => post({ type: "openTag", tag }));
      row.append(pill);
    }
    if (this.edited) row.append(el("span", "cm-doc-edited", this.edited));
    return row;
  }
  ignoreEvent() {
    return true;
  }
}

const yamlLine = Decoration.line({ class: "cm-lp-yaml" });
const titleLine = Decoration.line({ class: "cm-doc-title" });

function build(state: EditorState): DecorationSet {
  const decos: Range<Decoration>[] = [];
  const range = frontmatterRange(state);
  const fields = range ? readFields(yamlLines(state, range)) : { tags: [] as string[] };
  const header = new HeaderWidget(fields.cover, fields.icon);
  let bodyStart = 0;

  if (range) {
    const inside = state.selection.ranges.some((r) => r.from <= range.to);
    if (inside) {
      decos.push(Decoration.widget({ widget: header, block: true, side: -2 }).range(0));
      for (let pos = range.from; pos <= range.to; ) {
        const line = state.doc.lineAt(pos);
        decos.push(yamlLine.range(line.from));
        pos = line.to + 1;
      }
    } else {
      decos.push(Decoration.replace({ widget: header, block: true }).range(0, range.to));
    }
    bodyStart = range.to + 1;
  } else {
    decos.push(Decoration.widget({ widget: header, block: true, side: -2 }).range(0));
  }

  const modified = state.field(modifiedField);
  const edited = modified ? editedLabel(modified) : null;
  const meta = fields.tags.length || edited ? new MetaWidget(fields.tags, edited) : null;

  const title = bodyStart <= state.doc.length ? state.doc.lineAt(bodyStart) : null;
  if (title && /^# /.test(title.text)) {
    decos.push(titleLine.range(title.from));
    if (meta) decos.push(Decoration.widget({ widget: meta, block: true, side: 1 }).range(title.to));
  } else if (meta) {
    decos.push(Decoration.widget({ widget: meta, block: true, side: -1 }).range(Math.min(bodyStart, state.doc.length)));
  }
  return Decoration.set(decos, true);
}

const headerField = StateField.define<DecorationSet>({
  create: build,
  update(value, tr) {
    if (tr.docChanged || tr.selection || tr.effects.some((e) => e.is(setModified))) return build(tr.state);
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

export const docHeader: Extension = [modifiedField, headerField];
