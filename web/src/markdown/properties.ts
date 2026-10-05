// 屬性面板（仿 Obsidian 的 Properties）：frontmatter 的欄位顯示在標題下方，可以直接改值、改名、換型別、新增與刪除。
// 每次修改都是一般的文件編輯（可 undo、停止輸入後照常寫回），只替換那個欄位的行（frontmatter.ts）。
// 值的輸入框是 widget 內的 <input>，注音組字交給瀏覽器，組字結束後才改動文件；
// widget 以 updateDOM 更新同一份 DOM，正在輸入的欄位不會被重建。
// `icon`、`cover` 由文件頭（封面、圖示）處理，不在這裡顯示。
import { EditorSelection, StateEffect, StateField } from "@codemirror/state";
import { EditorView, WidgetType } from "@codemirror/view";
import { t } from "../shared/i18n";
import { el, post } from "./bridge";
import {
  convertValue,
  Entry,
  frontmatterEdit,
  frontmatterLines,
  frontmatterRange,
  PropType,
  PropValue,
  readEntries,
  renameEntry,
  setEntry,
} from "./frontmatter";

export const HIDDEN_KEYS = new Set(["icon", "cover"]);

// 正在新增屬性（顯示屬性名稱的輸入框）；沒有 frontmatter 時由文件頭的「新增屬性」打開
export const setAddingProperty = StateEffect.define<boolean>();

export const addingProperty = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setAddingProperty)) value = e.value;
    return value;
  },
});

const ICONS: Record<PropType, string> = {
  text: '<path d="M4 7h16M4 12h16M4 17h10"/>',
  list: '<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1"/><circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="18" r="1"/>',
  checkbox: '<rect x="4" y="4" width="16" height="16" rx="4"/><path d="m8.5 12 2.5 2.5 4.5-5"/>',
  date: '<rect x="3.5" y="5" width="17" height="15" rx="2.5"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
  raw: '<path d="m8 8-4 4 4 4M16 8l4 4-4 4"/>',
};

function icon(type: PropType): string {
  return `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[type]}</svg>`;
}

const CHECK = '<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';

function typeLabel(type: PropType): string {
  switch (type) {
    case "text": return t("文字");
    case "list": return t("清單");
    case "checkbox": return t("核取方塊");
    case "date": return t("日期");
    case "raw": return "YAML";
  }
}

// MARK: 讀寫

function currentEntries(view: EditorView): Entry[] {
  return readEntries(frontmatterLines(view.state));
}

function edit(view: EditorView, change: (lines: string[]) => string[], effects: StateEffect<unknown>[] = []) {
  const changes = frontmatterEdit(view.state, change);
  if (!changes && !effects.length) return;
  // 新增 frontmatter 時游標（文件開頭）留在它後面，否則會切到原始 YAML
  const set = view.state.changes(changes ?? []);
  view.dispatch({ changes: set, selection: view.state.selection.map(set, 1), effects, userEvent: "input.property" });
}

function setValue(view: EditorView, key: string, value: PropValue | null) {
  const entry = currentEntries(view).find((e) => e.key === key);
  if (entry && value && JSON.stringify(entry.value) === JSON.stringify(value)) return;
  edit(view, (lines) => setEntry(lines, key, value));
}

function revealSource(view: EditorView, key?: string) {
  const range = frontmatterRange(view.state);
  if (!range) return;
  const entry = key ? currentEntries(view).find((e) => e.key === key) : undefined;
  const line = view.state.doc.line(Math.min(2 + (entry?.start ?? 0), view.state.doc.lines));
  view.dispatch({ selection: EditorSelection.cursor(line.to), scrollIntoView: true });
  view.focus();
}

function rowOf(node: EventTarget | null): HTMLElement | null {
  return (node as HTMLElement | null)?.closest?.(".cm-prop[data-key]") ?? null;
}

function focusRow(view: EditorView, key: string, selector = ".cm-prop-input, .cm-prop-chip-input, .cm-prop-check") {
  const row = view.contentDOM.querySelector(`.cm-prop[data-key="${CSS.escape(key)}"]`);
  const target = row?.querySelector<HTMLElement>(selector);
  target?.focus();
}

// MARK: DOM

function valueNode(entry: Entry): HTMLElement {
  const box = el("div", "cm-prop-value");
  const v = entry.value;
  switch (v.type) {
    case "text":
    case "date": {
      const input = el("input", "cm-prop-input");
      input.type = v.type === "date" ? "date" : "text";
      input.value = v.value;
      input.placeholder = v.type === "text" ? t("空白") : "";
      input.spellcheck = false;
      input.dataset.focus = "value";
      box.append(input);
      break;
    }
    case "checkbox": {
      const check = el("span", "cm-lp-task cm-prop-check");
      check.tabIndex = 0;
      check.setAttribute("role", "checkbox");
      check.dataset.focus = "value";
      box.append(check);
      break;
    }
    case "list": {
      const chips = el("div", "cm-prop-chips");
      const input = el("input", "cm-prop-chip-input");
      input.placeholder = t("新增…");
      input.spellcheck = false;
      input.dataset.focus = "value";
      chips.append(input);
      box.append(chips);
      break;
    }
    case "raw": {
      const raw = el("span", "cm-prop-raw");
      raw.title = t("編輯原始 YAML");
      box.append(raw);
      break;
    }
  }
  return box;
}

function rowNode(entry: Entry): HTMLElement {
  const row = el("div", "cm-prop");
  row.dataset.key = entry.key;
  row.dataset.type = entry.value.type;
  const head = el("div", "cm-prop-head");
  const kind = el("span", "cm-prop-icon");
  kind.innerHTML = icon(entry.value.type);
  kind.title = typeLabel(entry.value.type);
  const key = el("input", "cm-prop-key");
  key.value = entry.key;
  key.spellcheck = false;
  key.dataset.focus = "key";
  head.append(kind, key);
  const remove = el("span", "cm-prop-del", "×");
  remove.title = t("刪除屬性");
  row.append(head, valueNode(entry), remove);
  return row;
}

// 值的部分（結構相同時也會更新；正在輸入的欄位不動）
function fillRow(row: HTMLElement, entry: Entry) {
  const v = entry.value;
  const key = row.querySelector<HTMLInputElement>(".cm-prop-key")!;
  if (key !== document.activeElement && key.value !== entry.key) key.value = entry.key;
  switch (v.type) {
    case "text":
    case "date": {
      const input = row.querySelector<HTMLInputElement>(".cm-prop-input")!;
      if (input !== document.activeElement && input.value !== v.value) input.value = v.value;
      break;
    }
    case "checkbox": {
      const check = row.querySelector<HTMLElement>(".cm-prop-check")!;
      check.classList.toggle("is-checked", v.value);
      check.setAttribute("aria-checked", String(v.value));
      check.innerHTML = v.value ? CHECK : "";
      break;
    }
    case "list": {
      const chips = row.querySelector<HTMLElement>(".cm-prop-chips")!;
      const input = chips.querySelector(".cm-prop-chip-input")!;
      const current = [...chips.querySelectorAll<HTMLElement>(".cm-prop-chip")].map((c) => c.dataset.value);
      if (current.join("\n") === v.items.join("\n") && current.length === v.items.length) break;
      chips.querySelectorAll(".cm-prop-chip").forEach((c) => c.remove());
      v.items.forEach((item, i) => {
        const chip = el("span", "cm-prop-chip");
        chip.dataset.value = item;
        chip.dataset.index = String(i);
        const text = el("span", "cm-prop-chip-text", item);
        const x = el("span", "cm-prop-chip-x", "×");
        chip.append(text, x);
        chips.insertBefore(chip, input);
      });
      break;
    }
    case "raw":
      row.querySelector(".cm-prop-raw")!.textContent = v.value || "…";
      break;
  }
}

function structure(entries: Entry[], adding: boolean): string {
  return entries.map((e) => `${e.key}\u0000${e.value.type}`).join("\u0001") + (adding ? "\u0002" : "");
}

function render(root: HTMLElement, widget: DocInfoWidget) {
  // 移除有焦點的輸入框會觸發 focusout；這時在 CodeMirror 的更新中，不能再改文件
  root.dataset.rendering = "1";
  root.replaceChildren();
  delete root.dataset.rendering;
  if (widget.showProps) {
    const props = el("div", "cm-props");
    for (const entry of widget.entries) {
      const row = rowNode(entry);
      fillRow(row, entry);
      props.append(row);
    }
    if (widget.adding) {
      const row = el("div", "cm-prop is-new");
      const head = el("div", "cm-prop-head");
      const kind = el("span", "cm-prop-icon");
      kind.innerHTML = icon("text");
      const input = el("input", "cm-prop-new");
      input.placeholder = t("屬性名稱");
      input.spellcheck = false;
      input.dataset.focus = "new";
      head.append(kind, input);
      row.append(head);
      props.append(row);
      setTimeout(() => input.isConnected && input.focus(), 0);
    }
    const foot = el("div", "cm-props-foot");
    const add = el("span", "cm-props-btn cm-props-add", t("＋ 新增屬性"));
    foot.append(add);
    if (widget.entries.length) foot.append(el("span", "cm-props-btn cm-props-source", t("編輯原始 YAML")));
    props.append(foot);
    root.append(props);
  }
  if (widget.edited) root.append(el("div", "cm-doc-meta", widget.edited));
  root.dataset.structure = structure(widget.entries, widget.adding);
  root.dataset.show = String(widget.showProps);
}

function sync(root: HTMLElement, widget: DocInfoWidget) {
  if (root.dataset.structure !== structure(widget.entries, widget.adding) || root.dataset.show !== String(widget.showProps)) {
    // 結構改變：重建後把焦點放回同一個欄位
    const active = document.activeElement as HTMLElement | null;
    const row = root.contains(active) ? rowOf(active) : null;
    const focus = row && active?.dataset.focus ? [row.dataset.key!, active.dataset.focus] : null;
    render(root, widget);
    if (focus) {
      const again = root.querySelector<HTMLElement>(`.cm-prop[data-key="${CSS.escape(focus[0])}"] [data-focus="${focus[1]}"]`);
      again?.focus();
    }
    return;
  }
  for (const entry of widget.entries) {
    const row = root.querySelector<HTMLElement>(`.cm-prop[data-key="${CSS.escape(entry.key)}"]`);
    if (row) fillRow(row, entry);
  }
  const meta = root.querySelector(".cm-doc-meta");
  if (meta && widget.edited) meta.textContent = widget.edited;
  else if (meta) meta.remove();
  else if (widget.edited) root.append(el("div", "cm-doc-meta", widget.edited));
}

// MARK: 事件

function commitValue(view: EditorView, row: HTMLElement) {
  const key = row.dataset.key!;
  const input = row.querySelector<HTMLInputElement>(".cm-prop-input");
  if (!input) return;
  setValue(view, key, row.dataset.type === "date" ? { type: "date", value: input.value } : { type: "text", value: input.value });
}

function commitKey(view: EditorView, row: HTMLElement, input: HTMLInputElement) {
  const from = row.dataset.key!;
  const to = input.value.trim();
  if (!to || to === from || currentEntries(view).some((e) => e.key === to)) {
    input.value = from;
    return;
  }
  edit(view, (lines) => renameEntry(lines, from, to));
}

function commitNew(view: EditorView, input: HTMLInputElement, focus = false) {
  const key = input.value.trim();
  if (!view.state.field(addingProperty)) return;
  if (!key) {
    view.dispatch({ effects: setAddingProperty.of(false) });
    return;
  }
  const exists = currentEntries(view).some((e) => e.key === key);
  edit(view, (lines) => (exists ? lines : setEntry(lines, key, { type: "text", value: "" })), [setAddingProperty.of(false)]);
  if (focus) focusRow(view, key);
}

function listItems(view: EditorView, key: string): string[] {
  const v = currentEntries(view).find((e) => e.key === key)?.value;
  return v?.type === "list" ? v.items : [];
}

function addChip(view: EditorView, row: HTMLElement, input: HTMLInputElement) {
  const values = input.value.split(/[,，]/).map((s) => s.trim()).filter(Boolean);
  input.value = "";
  if (!values.length) return;
  const key = row.dataset.key!;
  const items = listItems(view, key);
  setValue(view, key, { type: "list", items: [...items, ...values.filter((v) => !items.includes(v))] });
}

function closeMenu(root: HTMLElement) {
  root.querySelector(".cm-prop-menu")?.remove();
}

function openTypeMenu(view: EditorView, root: HTMLElement, row: HTMLElement, anchor: HTMLElement) {
  closeMenu(root);
  if (row.dataset.type === "raw") {
    revealSource(view, row.dataset.key);
    return;
  }
  const menu = el("div", "cm-prop-menu");
  for (const type of ["text", "list", "checkbox", "date"] as const) {
    const item = el("div", "cm-prop-menu-item");
    item.innerHTML = icon(type);
    item.append(typeLabel(type));
    if (type === row.dataset.type) item.classList.add("is-current");
    item.dataset.type = type;
    menu.append(item);
  }
  menu.addEventListener("mousedown", (e) => {
    e.preventDefault();
    e.stopPropagation();
    const type = (e.target as HTMLElement).closest<HTMLElement>(".cm-prop-menu-item")?.dataset.type as PropType | undefined;
    closeMenu(root);
    if (!type) return;
    const entry = currentEntries(view).find((x) => x.key === row.dataset.key);
    if (entry && entry.value.type !== type) setValue(view, entry.key, convertValue(entry.value, type));
  });
  root.append(menu);
  const box = root.getBoundingClientRect();
  const at = anchor.getBoundingClientRect();
  menu.style.top = `${at.bottom - box.top + 4}px`;
  menu.style.left = `${at.left - box.left}px`;
}

function attach(root: HTMLElement, view: EditorView) {
  root.addEventListener("mousedown", (e) => {
    const target = e.target as HTMLElement;
    if (!target.closest(".cm-prop-menu")) closeMenu(root);
    if (target.closest("input")) return;
    // 按鈕：按下就處理，不移動焦點
    e.preventDefault();
    const row = rowOf(target);
    const key = row?.dataset.key;
    if (target.closest(".cm-props-add")) {
      view.dispatch({ effects: setAddingProperty.of(true) });
    } else if (target.closest(".cm-props-source")) {
      revealSource(view);
    } else if (!row || !key) {
      return;
    } else if (target.closest(".cm-prop-del")) {
      setValue(view, key, null);
    } else if (target.closest(".cm-prop-icon")) {
      openTypeMenu(view, root, row, target.closest(".cm-prop-icon")!);
    } else if (target.closest(".cm-prop-check")) {
      const v = currentEntries(view).find((x) => x.key === key)?.value;
      if (v?.type === "checkbox") setValue(view, key, { type: "checkbox", value: !v.value });
    } else if (target.closest(".cm-prop-raw")) {
      revealSource(view, key);
    } else if (target.closest(".cm-prop-chip-x")) {
      const index = Number(target.closest<HTMLElement>(".cm-prop-chip")!.dataset.index);
      setValue(view, key, { type: "list", items: listItems(view, key).filter((_, i) => i !== index) });
    } else if (target.closest(".cm-prop-chip-text")) {
      if (key.toLowerCase() === "tags") post({ type: "openTag", tag: target.closest<HTMLElement>(".cm-prop-chip")!.dataset.value! });
    } else if (target.closest(".cm-prop-chips")) {
      row.querySelector<HTMLElement>(".cm-prop-chip-input")?.focus();
    }
  });
  root.addEventListener("input", (e) => {
    const target = e.target as HTMLElement;
    if (target.matches(".cm-prop-input") && !(e as InputEvent).isComposing) commitValue(view, rowOf(target)!);
  });
  root.addEventListener("change", (e) => {
    const target = e.target as HTMLElement;
    if (target.matches(".cm-prop-input")) commitValue(view, rowOf(target)!);
  });
  root.addEventListener("compositionend", (e) => {
    const target = e.target as HTMLElement;
    if (target.matches(".cm-prop-input")) commitValue(view, rowOf(target)!);
  });
  root.addEventListener("focusout", (e) => {
    const target = e.target as HTMLInputElement;
    if (!target.isConnected || root.dataset.rendering) return;
    const row = rowOf(target);
    if (target.matches(".cm-prop-key") && row) commitKey(view, row, target);
    else if (target.matches(".cm-prop-new")) commitNew(view, target);
    else if (target.matches(".cm-prop-chip-input") && row) addChip(view, row, target);
  });
  root.addEventListener("keydown", (e) => {
    const target = e.target as HTMLElement;
    // 組字中的 Enter 是輸入法在選字
    if (e.isComposing || e.keyCode === 229) return;
    const row = rowOf(target);
    const input = target as HTMLInputElement;
    const stop = () => (e.preventDefault(), e.stopPropagation());
    if (target.matches(".cm-prop-new")) {
      if (e.key === "Enter") stop(), commitNew(view, input, true);
      else if (e.key === "Escape") stop(), (input.value = ""), commitNew(view, input);
    } else if (target.matches(".cm-prop-key") && row) {
      if (e.key === "Enter") stop(), commitKey(view, row, input), focusRow(view, input.value.trim() || row.dataset.key!);
      else if (e.key === "Escape") stop(), (input.value = row.dataset.key!), input.blur();
    } else if (target.matches(".cm-prop-chip-input") && row) {
      if (e.key === "Enter" || e.key === ",") stop(), addChip(view, row, input);
      else if (e.key === "Backspace" && input.value === "") {
        const items = listItems(view, row.dataset.key!);
        if (items.length) stop(), setValue(view, row.dataset.key!, { type: "list", items: items.slice(0, -1) });
      }
    } else if (target.matches(".cm-prop-check") && row && (e.key === " " || e.key === "Enter")) {
      stop();
      const v = currentEntries(view).find((x) => x.key === row.dataset.key)?.value;
      if (v?.type === "checkbox") setValue(view, row.dataset.key!, { type: "checkbox", value: !v.value });
    } else if (target.matches(".cm-prop-input") && e.key === "Enter") {
      stop();
      input.blur();
    }
  });
}

// MARK: Widget

// 標題下方的區塊：屬性面板 + 最後編輯時間
export class DocInfoWidget extends WidgetType {
  readonly signature: string;
  constructor(readonly entries: Entry[], readonly edited: string | null, readonly adding: boolean, readonly showProps: boolean) {
    super();
    this.signature = JSON.stringify([entries.map((e) => [e.key, e.value]), edited, adding, showProps]);
  }
  eq(other: DocInfoWidget) {
    return other.signature === this.signature;
  }
  toDOM(view: EditorView) {
    const root = el("div", "cm-doc-info");
    render(root, this);
    attach(root, view);
    return root;
  }
  updateDOM(dom: HTMLElement) {
    sync(dom, this);
    return true;
  }
  ignoreEvent() {
    return true;
  }
}

// 文件頭判斷要不要顯示屬性面板
export function visibleEntries(lines: string[]): Entry[] {
  return readEntries(lines).filter((e) => !HIDDEN_KEYS.has(e.key));
}
