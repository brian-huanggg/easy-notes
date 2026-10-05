// 表格（GFM）顯示成可直接編輯的格子（仿 Notion）：點格子就能打字，Tab / Enter 移動，
// 底部與右側的「+」新增列欄，格子的「⋯」選單可插入、刪除、對齊與移動。游標（CodeMirror 的選取）進入表格範圍時改顯示原始 md。
// 每格是 contenteditable（不是 CodeMirror 管的內容），注音組字完全交給瀏覽器；
// 組字結束、或一般輸入時才改動文件，而且只替換那一格的文字（table.ts 的 cellChange）。
// widget 改用 updateDOM 更新同一份 DOM，正在打字的格子不會被重建、焦點不會跑掉。
// 事件處理一律在事件發生時從文件重新讀表格（posAtDOM），不保存可能過期的模型。
// block decoration 不能由 ViewPlugin 提供，所以用 StateField。
import { syntaxTree } from "@codemirror/language";
import { EditorSelection, EditorState, Extension, Range, StateField, Text } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import { editingRange, setEditorFocus } from "./editorFocus";
import { t } from "../shared/i18n";
import { el, onPress } from "./bridge";
import { lines as textLines } from "./lineBreak";
import { mathHTML, mathIsReady, mathLoaded } from "./math";
import {
  Align,
  cellChange,
  deleteColumn,
  deleteRow,
  insertColumn,
  insertRow,
  moveColumn,
  moveRow,
  parseTable,
  serializeTable,
  setAlign,
  sourceLineIndex,
  TableModel,
} from "./table";

interface TableSpan {
  from: number;
  to: number;
  model: TableModel;
}

// 文件最上層的表格（引言、清單裡的表格維持原始 md）
function tableAt(state: EditorState, node: { from: number; to: number }): TableSpan | null {
  const first = state.doc.lineAt(node.from);
  const last = state.doc.lineAt(node.to);
  if (first.from !== node.from && state.sliceDoc(first.from, node.from).trim() !== "") return null;
  const lines: string[] = [];
  for (let n = first.number; n <= last.number; n++) lines.push(state.doc.line(n).text);
  const model = parseTable(lines);
  return model ? { from: first.from, to: last.to, model } : null;
}

function tables(state: EditorState): TableSpan[] {
  const out: TableSpan[] = [];
  for (let node = syntaxTree(state).topNode.firstChild; node; node = node.nextSibling) {
    if (node.name !== "Table") continue;
    const span = tableAt(state, node);
    if (span) out.push(span);
  }
  return out;
}

// widget DOM → 它目前在文件中的表格
function locate(view: EditorView, wrap: HTMLElement): TableSpan | null {
  let pos: number;
  try {
    pos = view.posAtDOM(wrap);
  } catch {
    return null;
  }
  for (let node = syntaxTree(view.state).topNode.firstChild; node; node = node.nextSibling) {
    if (node.name === "Table" && view.state.doc.lineAt(node.from).from === pos) return tableAt(view.state, node);
    if (node.from > pos) break;
  }
  return null;
}

function cellAt(target: EventTarget | null): HTMLElement | null {
  return (target as HTMLElement | null)?.closest?.(".cm-table-cell") ?? null;
}

function coords(cell: HTMLElement): [number, number] {
  return [Number(cell.dataset.row), Number(cell.dataset.col)];
}

function setEditable(node: HTMLElement) {
  try {
    node.contentEditable = "plaintext-only";
  } catch {
    node.contentEditable = "true";
  }
}

function placeCaret(node: HTMLElement, selectAll: boolean) {
  node.focus();
  const sel = window.getSelection();
  if (!sel) return;
  const range = document.createRange();
  range.selectNodeContents(node);
  if (!selectAll) range.collapse(false);
  sel.removeAllRanges();
  sel.addRange(range);
}

const ICON_MORE = '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>';
const ICON_PLUS = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>';

function shape(model: TableModel): string {
  return `${model.header.length}x${model.rows.length}`;
}

function cssAlign(align: Align): string {
  return align ?? "";
}

// 格內 md 的簡易渲染（沒在編輯的格子）：粗體、斜體、刪除線、程式碼、連結、公式、`<br>`。
// 編輯時（焦點在格子）換回原始文字
const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
const escapeHTML = (s: string) => s.replace(/[&<>"]/g, (c) => ESCAPES[c]);

export function renderInline(raw: string): string {
  const slots: string[] = [];
  const slot = (html: string) => `\u0000${slots.push(html) - 1}\u0000`;
  let s = raw
    .replace(/`([^`]+)`/g, (_, code) => slot(`<code class="cm-lp-code">${escapeHTML(code)}</code>`))
    .replace(/\$([^\s$](?:[^$]*?[^\s$\\])?)\$(?!\d)/g, (m, tex) => slot(mathHTML(tex, false) ?? escapeHTML(m)));
  s = escapeHTML(s)
    .replace(/&lt;br\s*\/?&gt;/gi, "<br>")
    .replace(/\*\*(.+?)\*\*|__(.+?)__/g, (_, a, b) => `<strong>${a ?? b}</strong>`)
    .replace(/(?<![\w*])\*(?!\s)(.+?)\*(?!\w)|(?<![\w_])_(?!\s)(.+?)_(?!\w)/g, (_, a, b) => `<em>${a ?? b}</em>`)
    .replace(/~~(.+?)~~/g, '<span class="cm-lp-strike">$1</span>')
    .replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target, label) => `<span class="cm-lp-wikilink">${label ?? target}</span>`)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<span class="cm-lp-link">$1</span>');
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => slots[Number(i)]);
}

// 設定格子的原始文字；沒在編輯時顯示渲染後的樣子
function show(cell: HTMLElement, raw: string) {
  cell.dataset.raw = raw;
  if (cell === document.activeElement) return;
  if (/[*_`~\[$<]/.test(raw)) cell.innerHTML = renderInline(raw);
  else if (cell.textContent !== raw || cell.childElementCount) cell.textContent = raw;
}

// 依模型建立格子（結構改變時整個重建）
function renderGrid(wrap: HTMLElement, model: TableModel) {
  const table = wrap.querySelector("table")!;
  // 移除有焦點的格子會觸發 focusout；這時在 CodeMirror 的更新中，不能再改文件
  wrap.dataset.rendering = "1";
  table.replaceChildren();
  delete wrap.dataset.rendering;
  const all = [model.header, ...model.rows];
  all.forEach((cells, r) => {
    const tr = el("tr");
    cells.forEach((text, c) => {
      const td = el(r === 0 ? "th" : "td");
      td.style.textAlign = cssAlign(model.align[c]);
      const cell = el("div", "cm-table-cell");
      show(cell, text);
      setEditable(cell);
      cell.dataset.row = String(r);
      cell.dataset.col = String(c);
      cell.spellcheck = false;
      const more = el("span", "cm-table-more");
      more.innerHTML = ICON_MORE;
      more.title = t("表格選項");
      more.dataset.row = String(r);
      more.dataset.col = String(c);
      td.append(cell, more);
      tr.append(td);
    });
    table.append(tr);
  });
  wrap.dataset.shape = shape(model);
}

// 結構相同時只更新沒有在打字的格子
function syncGrid(wrap: HTMLElement, model: TableModel) {
  if (wrap.dataset.shape !== shape(model)) {
    const active = cellAt(document.activeElement);
    const at = active && wrap.contains(active) ? coords(active) : null;
    renderGrid(wrap, model);
    if (at) {
      const again = wrap.querySelector<HTMLElement>(`.cm-table-cell[data-row="${at[0]}"][data-col="${at[1]}"]`);
      if (again) placeCaret(again, false);
    }
    return;
  }
  const all = [model.header, ...model.rows];
  for (const cell of wrap.querySelectorAll<HTMLElement>(".cm-table-cell")) {
    const [r, c] = coords(cell);
    show(cell, all[r][c]);
    (cell.parentElement as HTMLElement).style.textAlign = cssAlign(model.align[c]);
  }
}

// MARK: 編輯

function editCell(view: EditorView, wrap: HTMLElement, cell: HTMLElement) {
  if (wrap.dataset.rendering || !cell.isConnected) return;
  const span = locate(view, wrap);
  if (!span) return;
  const [r, c] = coords(cell);
  const text = (cell.textContent ?? "").replace(/\n/g, " ");
  const all = [span.model.header, ...span.model.rows];
  if (all[r]?.[c] === text) return;
  const line = view.state.doc.lineAt(span.from).number + sourceLineIndex(r);
  const { from, text: lineText } = view.state.doc.line(line);
  const change = cellChange(lineText, c, text);
  view.dispatch({ changes: { from: from + change.from, to: from + change.to, insert: change.insert }, userEvent: "input.table" });
}

function findWrap(view: EditorView, from: number): HTMLElement | null {
  for (const wrap of view.contentDOM.querySelectorAll<HTMLElement>(".cm-table")) {
    try {
      if (view.posAtDOM(wrap) === from) return wrap;
    } catch {
      // 已移除的節點
    }
  }
  return null;
}

export function focusCell(view: EditorView, from: number, row: number, col: number, selectAll = false) {
  const wrap = findWrap(view, from);
  const cell = wrap?.querySelector<HTMLElement>(`.cm-table-cell[data-row="${row}"][data-col="${col}"]`);
  if (cell) placeCaret(cell, selectAll);
}

// 整個表格重寫（列欄操作），之後把焦點放到指定的格子
function restructure(view: EditorView, wrap: HTMLElement, op: (model: TableModel) => TableModel, focus?: (model: TableModel) => [number, number]) {
  // 先讓正在打字的格子寫回並失去焦點：之後所有格子都依新內容更新（移動列欄時位置會換）
  const active = cellAt(document.activeElement);
  if (active && wrap.contains(active)) active.blur();
  const span = locate(view, wrap);
  if (!span) return;
  const model = op(span.model);
  view.dispatch({ changes: { from: span.from, to: span.to, insert: textLines(serializeTable(model).join("\n")) }, userEvent: "input.table" });
  if (focus) {
    const [r, c] = focus(model);
    focusCell(view, span.from, r, c);
  }
}

function revealSource(view: EditorView, wrap: HTMLElement) {
  const span = locate(view, wrap);
  if (!span) return;
  view.dispatch({ selection: EditorSelection.cursor(span.from), scrollIntoView: true });
  view.focus();
}

// 離開表格：游標放到表格下一行
function leave(view: EditorView, wrap: HTMLElement) {
  const span = locate(view, wrap);
  if (!span) return;
  if (span.to >= view.state.doc.length) view.dispatch({ changes: { from: span.to, insert: Text.of(["", ""]) } });
  view.dispatch({ selection: EditorSelection.cursor(span.to + 1), scrollIntoView: true });
  view.focus();
}

function move(view: EditorView, wrap: HTMLElement, cell: HTMLElement, dr: number, dc: number, grow: boolean) {
  const span = locate(view, wrap);
  if (!span) return;
  const cols = span.model.header.length;
  const rows = span.model.rows.length + 1;
  let [r, c] = coords(cell);
  c += dc;
  if (c >= cols) (c = 0), r++;
  if (c < 0) (c = cols - 1), r--;
  r += dr;
  if (r < 0) return;
  if (r >= rows) {
    if (grow) restructure(view, wrap, (m) => insertRow(m, m.rows.length), () => [r, c]);
    else leave(view, wrap);
    return;
  }
  focusCell(view, span.from, r, c);
}

// MARK: 選單

function closeMenu(wrap: HTMLElement) {
  wrap.querySelector(".cm-table-menu")?.remove();
}

function openMenu(view: EditorView, wrap: HTMLElement, anchor: HTMLElement) {
  closeMenu(wrap);
  const span = locate(view, wrap);
  if (!span) return;
  const [r, c] = coords(anchor);
  const row = r - 1; // 內容列的索引；標題列是 -1
  const cols = span.model.header.length;
  const menu = el("div", "cm-table-menu");
  const item = (label: string, action: () => void, enabled = true) => {
    const node = el("div", "cm-table-menu-item" + (enabled ? "" : " is-disabled"), label);
    if (enabled) onPress(node, () => (closeMenu(wrap), action()));
    menu.append(node);
  };
  const separator = () => menu.append(el("div", "cm-table-menu-sep"));
  item(t("在上方插入列"), () => restructure(view, wrap, (m) => insertRow(m, row), () => [r, c]), row >= 0);
  item(t("在下方插入列"), () => restructure(view, wrap, (m) => insertRow(m, row + 1), () => [r + 1, c]));
  item(t("在左側插入欄"), () => restructure(view, wrap, (m) => insertColumn(m, c), () => [r, c]));
  item(t("在右側插入欄"), () => restructure(view, wrap, (m) => insertColumn(m, c + 1), () => [r, c + 1]));
  separator();
  item(t("上移一列"), () => restructure(view, wrap, (m) => moveRow(m, row, row - 1), () => [r - 1, c]), row > 0);
  item(t("下移一列"), () => restructure(view, wrap, (m) => moveRow(m, row, row + 1), () => [r + 1, c]), row >= 0 && row < span.model.rows.length - 1);
  item(t("左移一欄"), () => restructure(view, wrap, (m) => moveColumn(m, c, c - 1), () => [r, c - 1]), c > 0);
  item(t("右移一欄"), () => restructure(view, wrap, (m) => moveColumn(m, c, c + 1), () => [r, c + 1]), c < cols - 1);
  separator();
  const current = span.model.align[c];
  for (const [align, label] of [["left", t("靠左對齊")], ["center", t("置中對齊")], ["right", t("靠右對齊")]] as const) {
    item((current === align ? "✓ " : "") + label, () => restructure(view, wrap, (m) => setAlign(m, c, current === align ? null : align), () => [r, c]));
  }
  separator();
  item(t("刪除列"), () => restructure(view, wrap, (m) => deleteRow(m, row), (m) => [Math.min(r, m.rows.length), c]), row >= 0);
  item(t("刪除欄"), () => restructure(view, wrap, (m) => deleteColumn(m, c), (m) => [r, Math.min(c, m.header.length - 1)]), cols > 1);
  item(t("編輯 Markdown 原始碼"), () => revealSource(view, wrap));
  wrap.append(menu);
  // 放在「⋯」下方，超出右邊就往左
  const box = wrap.getBoundingClientRect();
  const at = anchor.getBoundingClientRect();
  menu.style.top = `${at.bottom - box.top + 4}px`;
  menu.style.left = `${Math.max(0, Math.min(at.left - box.left, box.width - menu.offsetWidth))}px`;
}

// MARK: Widget

class TableWidget extends WidgetType {
  constructor(readonly model: TableModel, readonly source: string, readonly math = mathIsReady()) {
    super();
  }
  eq(other: TableWidget) {
    return other.source === this.source && other.math === this.math;
  }
  get estimatedHeight() {
    return (this.model.rows.length + 1) * 38 + 16;
  }
  toDOM(view: EditorView) {
    const wrap = el("div", "cm-table");
    wrap.contentEditable = "false";
    const scroll = el("div", "cm-table-scroll");
    scroll.append(el("table"));
    const addRow = el("div", "cm-table-add-row");
    addRow.innerHTML = ICON_PLUS;
    addRow.title = t("新增列");
    const addCol = el("div", "cm-table-add-col");
    addCol.innerHTML = ICON_PLUS;
    addCol.title = t("新增欄");
    wrap.append(scroll, addRow, addCol);
    renderGrid(wrap, this.model);

    onPress(addRow, () => restructure(view, wrap, (m) => insertRow(m, m.rows.length), (m) => [m.rows.length, 0]));
    onPress(addCol, () => restructure(view, wrap, (m) => insertColumn(m, m.header.length), (m) => [0, m.header.length - 1]));
    wrap.addEventListener("mousedown", (e) => {
      const more = (e.target as HTMLElement).closest(".cm-table-more") as HTMLElement | null;
      if (more) {
        e.preventDefault();
        if (wrap.querySelector(".cm-table-menu")) closeMenu(wrap);
        else openMenu(view, wrap, more);
        return;
      }
      if (!(e.target as HTMLElement).closest(".cm-table-menu")) closeMenu(wrap);
    });
    wrap.addEventListener("input", (e) => {
      const cell = cellAt(e.target);
      if (cell && !(e as InputEvent).isComposing) editCell(view, wrap, cell);
    });
    wrap.addEventListener("compositionend", (e) => {
      const cell = cellAt(e.target);
      if (cell) editCell(view, wrap, cell);
    });
    wrap.addEventListener("focusin", (e) => {
      // 開始編輯：換回原始文字，游標放到最後
      const cell = cellAt(e.target);
      if (cell && (cell.childElementCount || cell.textContent !== cell.dataset.raw)) {
        cell.textContent = cell.dataset.raw ?? "";
        placeCaret(cell, false);
      }
    });
    wrap.addEventListener("focusout", (e) => {
      const cell = cellAt(e.target);
      if (!cell) return;
      editCell(view, wrap, cell);
      if (cell.isConnected && !wrap.dataset.rendering) show(cell, (cell.textContent ?? "").replace(/\n/g, " "));
    });
    wrap.addEventListener("keydown", (e) => {
      const cell = cellAt(e.target);
      // 組字中的 Enter、方向鍵是輸入法在選字
      if (!cell || e.isComposing || e.keyCode === 229) return;
      const handled = () => (e.preventDefault(), e.stopPropagation());
      if (e.key === "Tab") {
        handled();
        move(view, wrap, cell, 0, e.shiftKey ? -1 : 1, !e.shiftKey);
      } else if (e.key === "Enter") {
        handled();
        if (!e.shiftKey) move(view, wrap, cell, 1, 0, true);
      } else if (e.key === "ArrowUp" || e.key === "ArrowDown") {
        handled();
        move(view, wrap, cell, e.key === "ArrowUp" ? -1 : 1, 0, false);
      } else if (e.key === "Escape") {
        handled();
        closeMenu(wrap);
        leave(view, wrap);
      }
    });
    return wrap;
  }
  updateDOM(dom: HTMLElement) {
    syncGrid(dom, this.model);
    return true;
  }
  // 格子內的鍵盤、滑鼠、組字都不交給 CodeMirror
  ignoreEvent() {
    return true;
  }
}

function build(state: EditorState): DecorationSet {
  const decos: Range<Decoration>[] = [];
  for (const span of tables(state)) {
    const editing = editingRange(state, span.from, span.to);
    if (editing) continue;
    decos.push(Decoration.replace({ widget: new TableWidget(span.model, state.sliceDoc(span.from, span.to)), block: true }).range(span.from, span.to));
  }
  return Decoration.set(decos);
}

const tableField = StateField.define<DecorationSet>({
  create: build,
  update(value, tr) {
    if (tr.docChanged || tr.selection || syntaxTree(tr.state) !== syntaxTree(tr.startState) || tr.effects.some((e) => e.is(mathLoaded) || e.is(setEditorFocus))) return build(tr.state);
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

export const tableWidgets: Extension = tableField;
