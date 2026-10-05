// 文件頭：frontmatter（檔案開頭的 `---` YAML 區塊）顯示為封面、icon，第一行 `# 標題` 顯示為大標題，
// 標題下方是屬性面板（properties.ts）與最後編輯時間。游標進入 frontmatter 時才顯示原始 YAML。
// frontmatter 的判斷與寫入規則見 frontmatter.ts（與 Swift 端 KindMarkdown/Frontmatter.swift 一致）：
// 寫入只改動目標欄位的行，其餘位元組不變。
import { EditorState, Extension, Range, StateEffect, StateField, Text } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { t } from "../shared/i18n";
import { editedLabel, el, onPress, post, vaultURL } from "./bridge";
import { frontmatterEdit, frontmatterLines, frontmatterRange, readEntries, setEntry } from "./frontmatter";
import { addingProperty, DocInfoWidget, setAddingProperty, visibleEntries } from "./properties";

export { frontmatterRange };

// 設定（value 非 null）或移除頂層欄位的變更（封面、圖示）。沒有 frontmatter 時新增一個；移除後 frontmatter 變空就整個刪掉，
// 讓「設定再移除」回到原本的位元組。沒有要改的時候回傳 null。
export function frontmatterChange(state: EditorState, key: string, value: string | null): { from: number; to: number; insert: Text } | null {
  return frontmatterEdit(state, (lines) => setEntry(lines, key, value === null ? null : { type: "text", value }));
}

// 以一般的編輯送出：可以 undo，並照常在停止輸入後寫回檔案
export function setFrontmatterField(view: EditorView, key: string, value: string | null) {
  const changes = frontmatterChange(view.state, key, value);
  if (!changes) return;
  // 新增 frontmatter 時游標（文件開頭）留在它後面，否則會切到原始 YAML
  const set = view.state.changes(changes);
  view.dispatch({ changes: set, selection: view.state.selection.map(set, 1) });
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

const ICON_PROPS = '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1"/><circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="18" r="1"/></svg>';

class HeaderWidget extends WidgetType {
  constructor(readonly cover: string | undefined, readonly icon: string | undefined, readonly hasProps: boolean) {
    super();
  }
  eq(other: HeaderWidget) {
    return other.cover === this.cover && other.icon === this.icon && other.hasProps === this.hasProps;
  }
  toDOM(view: EditorView) {
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
      if (!this.hasProps) tools.append(headerButton(ICON_PROPS, t("新增屬性"), () => view.dispatch({ effects: setAddingProperty.of(true) })));
      box.append(img, tools);
      root.append(box);
    } else {
      // 沒有封面：游標移到文件頭時才出現的新增按鈕
      const add = el("div", "cm-doc-add");
      add.append(headerButton(ICON_IMAGE, t("新增封面"), pickCover));
      if (!icon) add.append(headerButton(ICON_SMILE, t("新增圖示"), pickIcon));
      if (!this.hasProps) add.append(headerButton(ICON_PROPS, t("新增屬性"), () => view.dispatch({ effects: setAddingProperty.of(true) })));
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

const yamlLine = Decoration.line({ class: "cm-lp-yaml" });
const titleLine = Decoration.line({ class: "cm-doc-title" });

function textField(entries: ReturnType<typeof readEntries>, key: string): string | undefined {
  const v = entries.find((e) => e.key === key)?.value;
  return v?.type === "text" && v.value ? v.value : undefined;
}

function build(state: EditorState): DecorationSet {
  const decos: Range<Decoration>[] = [];
  const range = frontmatterRange(state);
  const lines = frontmatterLines(state, range);
  const entries = readEntries(lines);
  const props = visibleEntries(lines);
  const header = new HeaderWidget(textField(entries, "cover"), textField(entries, "icon"), props.length > 0);
  let bodyStart = 0;
  let inside = false;

  if (range) {
    inside = state.selection.ranges.some((r) => r.from <= range.to);
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
  // 顯示原始 YAML 時不重複顯示屬性面板
  const adding = state.field(addingProperty) && !inside;
  const showProps = !inside && (props.length > 0 || adding);
  const info = showProps || edited ? new DocInfoWidget(showProps ? props : [], edited, adding, showProps) : null;

  const title = bodyStart <= state.doc.length ? state.doc.lineAt(bodyStart) : null;
  if (title && /^# /.test(title.text)) {
    decos.push(titleLine.range(title.from));
    if (info) decos.push(Decoration.widget({ widget: info, block: true, side: 1 }).range(title.to));
  } else if (info) {
    decos.push(Decoration.widget({ widget: info, block: true, side: -1 }).range(Math.min(bodyStart, state.doc.length)));
  }
  return Decoration.set(decos, true);
}

const headerField = StateField.define<DecorationSet>({
  create: build,
  update(value, tr) {
    if (tr.docChanged || tr.selection || tr.effects.some((e) => e.is(setModified) || e.is(setAddingProperty))) return build(tr.state);
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

export const docHeader: Extension = [modifiedField, addingProperty, headerField];
