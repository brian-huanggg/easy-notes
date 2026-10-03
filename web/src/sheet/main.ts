// EasyNotes 表格編輯器：RevoGrid（內建編輯器，S5 Spike 驗證過注音）+ Swift Bridge
//
// Bridge 協定（見 docs/architecture/sheets.md）：
//   Swift → JS : window.sheet.load / applyRemote / applyMeta / exec / flush / focus
//   JS → Swift : ready / edit / meta
// 打字的熱路徑不跨 Bridge：edit 只在儲存格編輯結束時送出。Undo 在 JS 端以 op 堆疊實作，
// 復原也是一般的 edit（Swift 不區分）。排序與篩選只影響畫面；「依此欄排序並寫入」才送 order。
// 顯示設定（欄寬、凍結欄、標題列）在 JS 改，整份以 meta 送出，Swift 寫進 `.csv.meta.json`。
import type { BeforeRangeSaveDataDetails, BeforeSaveDataDetails, ColumnRegular } from "@revolist/revogrid";
import { defineCustomElement } from "@revolist/revogrid/standalone/revo-grid.js";
import { locale } from "../shared/i18n";
import { Meta, Op, post, postEdit, postMeta } from "./bridge";

defineCustomElement();

/** 一列：`__id` 是 Swift 給的穩定 row id（JS 新增的列用負數），欄位以 0, 1, 2… 為 key */
type Row = { __id: number; [col: number]: string };
interface Payload {
  rows: { id: number; cells: string[] }[];
  readOnly?: boolean;
  meta?: Meta;
}
interface Entry {
  forward: Op[];
  backward: Op[];
}
interface CellRef {
  id: number;
  col: number;
}

const grid = document.createElement("revo-grid");
grid.range = true;
grid.resize = true;
grid.useClipboard = true; // 複製貼上是 TSV，與 Numbers / Excel 互通
grid.rowHeaders = true;
grid.filter = true;
grid.applyOnClose = true; // 編輯中失焦（切換檔案、進背景）也保存
document.getElementById("sheet")!.appendChild(grid);

const dark = window.matchMedia("(prefers-color-scheme: dark)");
const applyTheme = () => (grid.theme = dark.matches ? "darkCompact" : "compact");
applyTheme();
dark.addEventListener("change", applyTheme);

/** 檔案順序；`meta.headerRow` 時第一列是標題列，固定在上方，不參與排序與篩選 */
let rows: Row[] = [];
let byId = new Map<number, Row>();
let width = 0;
let readOnly = false;
let meta: Meta = defaultMeta();
let nextLocalId = -1;
let undoStack: Entry[] = [];
let redoStack: Entry[] = [];
/** beforeedit / beforerangeedit 記下的修改（含舊值），afteredit 時一次送出 */
let pending: { id: number; col: number; old: string; value: string }[] = [];
/** 儲存格編輯中收到的外部變動：編輯結束後才套用，否則關閉編輯器時舊值會蓋掉新內容 */
let deferredRemote: string | null = null;

const collator = new Intl.Collator(locale, { numeric: true, sensitivity: "base" });
/** 空白排在最後，其餘依語言排序（數字依數值） */
function compareCells(a: string, b: string): number {
  if (a === "" || b === "") return a === b ? 0 : a === "" ? 1 : -1;
  return collator.compare(a, b);
}

const defaultWidth = 140;

function defaultMeta(): Meta {
  return { version: 1, columns: [], frozenColumns: 0, headerRow: true };
}

/** 去掉結尾的預設欄位（與 Swift 的 `SheetMeta` 相同），相同的設定送出相同的內容 */
function normalizeMeta(m: Meta): Meta {
  const columns = m.columns.map((c) => (typeof c?.width === "number" ? { width: c.width } : {}));
  while (columns.length > 0 && !("width" in columns[columns.length - 1])) columns.pop();
  return { version: m.version ?? 1, columns, frozenColumns: Math.max(0, m.frozenColumns ?? 0), headerRow: m.headerRow ?? true };
}

function updateMeta(change: (m: Meta) => void) {
  const before = JSON.stringify(meta);
  change(meta);
  meta = normalizeMeta(meta);
  if (JSON.stringify(meta) !== before) postMeta(meta);
}

/** 標題列（固定在上方的第一列）的 id；沒有標題列時為 undefined */
function headerId(): number | undefined {
  return meta.headerRow ? rows[0]?.__id : undefined;
}

function cell(row: Row, col: number): string {
  return row[col] ?? "";
}

function cellsOf(row: Row): string[] {
  return Array.from({ length: width }, (_, i) => cell(row, i));
}

function makeRow(id: number, cells: string[]): Row {
  const row: Row = { __id: id };
  cells.forEach((value, i) => (row[i] = value));
  return row;
}

/** A, B, …, Z, AA, AB… */
function columnName(i: number): string {
  let name = "";
  for (let n = i + 1; n > 0; n = Math.floor((n - 1) / 26)) name = String.fromCharCode(65 + ((n - 1) % 26)) + name;
  return name;
}

function columns(): ColumnRegular[] {
  return Array.from({ length: width }, (_, i) => ({
    prop: i,
    name: columnName(i),
    size: meta.columns[i]?.width ?? defaultWidth,
    sortable: true,
    pin: i < meta.frozenColumns ? "colPinStart" : undefined,
    cellCompare: (prop, a, b) => compareCells(String(a[prop] ?? ""), String(b[prop] ?? "")),
  }));
}

function render() {
  byId = new Map(rows.map((row) => [row.__id, row]));
  grid.columns = columns();
  const header = meta.headerRow ? 1 : 0;
  grid.pinnedTopSource = rows.slice(0, header);
  grid.source = rows.slice(header);
  grid.readonly = readOnly;
}

function loadRows(payload: Payload) {
  rows = payload.rows.map((r) => makeRow(r.id, r.cells));
  width = Math.max(0, ...payload.rows.map((r) => r.cells.length));
}

// MARK: 選取

async function focused(): Promise<CellRef | null> {
  const focus = await grid.getFocused();
  const id = focus?.model?.__id;
  if (typeof id !== "number" || focus?.column === undefined) return null;
  return { id, col: Number(focus.column.prop) };
}

/** 選取範圍內的列（檔案中的 id）；沒有範圍時用目前的儲存格 */
async function selectedRowIds(): Promise<number[]> {
  const range = await grid.getSelectedRange();
  if (range) {
    if (range.rowType === "rowPinStart") return headerId() !== undefined ? [headerId()!] : [];
    const visible = (await grid.getVisibleSource("rgRow")) as Row[];
    return visible.slice(Math.min(range.y, range.y1), Math.max(range.y, range.y1) + 1).map((r) => r.__id);
  }
  const ref = await focused();
  return ref ? [ref.id] : [];
}

async function restoreFocus(ref: CellRef | null) {
  if (!ref || !byId.has(ref.id) || ref.col >= width) return;
  const pinned = ref.col < meta.frozenColumns;
  const colType = pinned ? "colPinStart" : "rgCol";
  const x = pinned ? ref.col : ref.col - meta.frozenColumns;
  if (headerId() === ref.id) {
    await grid.setCellsFocus({ x, y: 0 }, { x, y: 0 }, colType, "rowPinStart");
    return;
  }
  const visible = (await grid.getVisibleSource("rgRow")) as Row[];
  const y = visible.findIndex((r) => r.__id === ref.id);
  if (y >= 0) await grid.setCellsFocus({ x, y }, { x, y }, colType, "rgRow");
}

// MARK: 套用 op（Undo / Redo 與指令共用；儲存格編輯由 RevoGrid 自己改畫面）

function applyLocal(op: Op) {
  switch (op.op) {
    case "set": {
      const row = byId.get(op.row);
      if (row) row[op.col] = op.value;
      width = Math.max(width, op.col + 1);
      break;
    }
    case "insertRows": {
      const at = op.before === null ? rows.length : rows.findIndex((r) => r.__id === op.before);
      const added = op.rows.map((r) => makeRow(r.id, r.cells));
      rows.splice(at < 0 ? rows.length : at, 0, ...added);
      added.forEach((row) => byId.set(row.__id, row));
      break;
    }
    case "deleteRows": {
      const remove = new Set(op.rows);
      rows = rows.filter((r) => !remove.has(r.__id));
      break;
    }
    case "insertColumn":
      for (const row of rows) {
        for (let i = width; i > op.at; i--) row[i] = cell(row, i - 1);
        row[op.at] = "";
      }
      width += 1;
      // 顯示設定跟著移動：插入的欄是預設寬度，插在凍結範圍內就多凍結一欄
      updateMeta((m) => {
        if (op.at < m.columns.length) m.columns.splice(op.at, 0, {});
        if (op.at < m.frozenColumns) m.frozenColumns += 1;
      });
      break;
    case "deleteColumn":
      for (const row of rows) {
        for (let i = op.at; i < width - 1; i++) row[i] = cell(row, i + 1);
        delete row[width - 1];
      }
      width = Math.max(0, width - 1);
      updateMeta((m) => {
        if (op.at < m.columns.length) m.columns.splice(op.at, 1);
        if (op.at < m.frozenColumns) m.frozenColumns -= 1;
      });
      break;
    case "order":
      rows = op.rows.map((id) => byId.get(id)).filter((r): r is Row => r !== undefined);
      break;
  }
}

async function run(ops: Op[]) {
  const ref = await focused();
  ops.forEach(applyLocal);
  render();
  postEdit(ops);
  await restoreFocus(ref);
}

async function perform(entry: Entry) {
  if (readOnly || entry.forward.length === 0) return;
  undoStack.push(entry);
  redoStack = [];
  await run(entry.forward);
}

async function undo() {
  const entry = undoStack.pop();
  if (!entry || readOnly) return;
  redoStack.push(entry);
  await run(entry.backward);
}

async function redo() {
  const entry = redoStack.pop();
  if (!entry || readOnly) return;
  undoStack.push(entry);
  await run(entry.forward);
}

// MARK: 儲存格編輯（打字、貼上、清除、自動填滿）

grid.addEventListener("beforeedit", (e: CustomEvent<BeforeSaveDataDetails>) => {
  const { prop, val } = e.detail;
  const model = e.detail.model as Row;
  pending.push({ id: model.__id, col: Number(prop), old: cell(model, Number(prop)), value: String(val ?? "") });
});

grid.addEventListener("beforerangeedit", (e: CustomEvent<BeforeRangeSaveDataDetails>) => {
  for (const [index, changes] of Object.entries(e.detail.data)) {
    const model = e.detail.models[Number(index)] as Row | undefined;
    if (!model) continue;
    for (const [prop, val] of Object.entries(changes)) {
      if (prop === "__id") continue;
      pending.push({ id: model.__id, col: Number(prop), old: cell(model, Number(prop)), value: String(val ?? "") });
    }
  }
});

grid.addEventListener("afteredit", () => {
  const changes = pending.filter((c) => c.old !== c.value && byId.has(c.id));
  pending = [];
  if (changes.length === 0) return;
  for (const c of changes) byId.get(c.id)![c.col] = c.value;
  const forward = changes.map((c): Op => ({ op: "set", row: c.id, col: c.col, value: c.value }));
  const backward = changes.map((c): Op => ({ op: "set", row: c.id, col: c.col, value: c.old })).reverse();
  undoStack.push({ forward, backward });
  redoStack = [];
  postEdit(forward);
  // 編輯中有外部變動：換成新內容後再疊上剛才的修改（Swift 端也是這個順序）
  if (deferredRemote !== null) void applyDeferredRemote(forward);
});

/** 拖曳調整欄寬：detail 的 key 是欄位在各自區域（凍結 / 一般）內的位置，以 prop 對回欄位 */
grid.addEventListener("aftercolumnresize", (e: CustomEvent<Record<number, ColumnRegular>>) => {
  updateMeta((m) => {
    for (const column of Object.values(e.detail)) {
      const col = Number(column.prop);
      if (!Number.isInteger(col) || typeof column.size !== "number") continue;
      while (m.columns.length <= col) m.columns.push({});
      m.columns[col] = { width: Math.round(column.size) };
    }
  });
});

/** 編輯器沒有保存就關閉（Esc）時，afteredit 不會觸發 */
grid.addEventListener("focusout", () => {
  setTimeout(() => {
    if (deferredRemote !== null && !isEditingCell()) void applyDeferredRemote([]);
  });
});

async function applyDeferredRemote(ops: Op[]) {
  const json = deferredRemote;
  deferredRemote = null;
  if (json === null) return;
  const ref = await focused();
  loadRows(JSON.parse(json));
  byId = new Map(rows.map((row) => [row.__id, row]));
  ops.forEach(applyLocal);
  render();
  await restoreFocus(ref);
}

// MARK: 指令（Swift 的「表格」選單）

async function insertRow(below: boolean) {
  const ref = await focused();
  let at = ref ? rows.findIndex((r) => r.__id === ref.id) : rows.length;
  if (at < 0) at = rows.length;
  if (ref && below) at += 1;
  const id = nextLocalId--;
  await perform({
    forward: [{ op: "insertRows", before: rows[at]?.__id ?? null, rows: [{ id, cells: Array(width).fill("") }] }],
    backward: [{ op: "deleteRows", rows: [id] }],
  });
}

async function deleteRows() {
  const ids = new Set(await selectedRowIds());
  if (ids.size === 0) return;
  // 依檔案順序逐列插回，插在它之後第一個沒被刪的列之前
  const backward: Op[] = [];
  rows.forEach((row, i) => {
    if (!ids.has(row.__id)) return;
    const next = rows.slice(i + 1).find((r) => !ids.has(r.__id));
    backward.push({ op: "insertRows", before: next?.__id ?? null, rows: [{ id: row.__id, cells: cellsOf(row) }] });
  });
  await perform({ forward: [{ op: "deleteRows", rows: [...ids] }], backward });
}

async function insertColumn(right: boolean) {
  const ref = await focused();
  const at = ref ? ref.col + (right ? 1 : 0) : width;
  await perform({ forward: [{ op: "insertColumn", at }], backward: [{ op: "deleteColumn", at }] });
}

async function deleteColumn() {
  const ref = await focused();
  if (!ref) return;
  const at = ref.col;
  const restore: Op[] = rows
    .filter((row) => cell(row, at) !== "")
    .map((row): Op => ({ op: "set", row: row.__id, col: at, value: cell(row, at) }));
  await perform({ forward: [{ op: "deleteColumn", at }], backward: [{ op: "insertColumn", at }, ...restore] });
}

/** 依目前欄排序並寫入檔案；標題列不動 */
async function sortAndWrite(descending: boolean) {
  const ref = await focused();
  const header = rows.slice(0, meta.headerRow ? 1 : 0);
  const body = rows.slice(header.length);
  if (!ref || body.length < 2) return;
  const sorted = [...body].sort((a, b) => {
    const order = compareCells(cell(a, ref.col), cell(b, ref.col));
    // 空白一律在最後
    if (cell(a, ref.col) === "" || cell(b, ref.col) === "") return order;
    return descending ? -order : order;
  });
  const before = rows.map((r) => r.__id);
  const after = [...header, ...sorted].map((r) => r.__id);
  if (before.every((id, i) => id === after[i])) return;
  grid.clearSorting();
  await perform({ forward: [{ op: "order", rows: after }], backward: [{ op: "order", rows: before }] });
}

/** 顯示設定改變後重畫，保留選取的儲存格 */
async function rerender(change: () => void) {
  const ref = await focused();
  change();
  render();
  await restoreFocus(ref);
}

/** 凍結首欄；已經凍結（不論幾欄）就取消 */
async function toggleFreeze() {
  await rerender(() => updateMeta((m) => (m.frozenColumns = m.frozenColumns > 0 ? 0 : 1)));
}

/** 第一列是標題（固定在上方）或一般資料列；切換時清掉畫面上的排序 */
async function toggleHeaderRow() {
  grid.clearSorting();
  await rerender(() => updateMeta((m) => (m.headerRow = !m.headerRow)));
}

const commands: Record<string, () => Promise<void>> = {
  insertRowAbove: () => insertRow(false),
  insertRowBelow: () => insertRow(true),
  deleteRows,
  insertColumnLeft: () => insertColumn(false),
  insertColumnRight: () => insertColumn(true),
  deleteColumn,
  sortAscending: () => sortAndWrite(false),
  sortDescending: () => sortAndWrite(true),
  toggleFreeze,
  toggleHeaderRow,
  undo,
  redo,
};

/** 儲存格編輯器（RevoGrid 的 input / textarea）是否開著；開著時 ⌘Z 交給輸入框 */
function isEditingCell(): boolean {
  const active = document.activeElement;
  return active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement;
}

document.addEventListener(
  "keydown",
  (e) => {
    if (!(e.metaKey || e.ctrlKey) || e.altKey || isEditingCell()) return;
    const key = e.key.toLowerCase();
    if (key === "z" || key === "y") {
      e.preventDefault();
      e.stopPropagation();
      void (key === "y" || e.shiftKey ? redo() : undo());
    }
  },
  true,
);

// MARK: Swift → JS

const api = {
  load(json: string) {
    const payload: Payload = JSON.parse(json);
    loadRows(payload);
    readOnly = payload.readOnly ?? false;
    meta = normalizeMeta(payload.meta ?? defaultMeta());
    undoStack = [];
    redoStack = [];
    pending = [];
    deferredRemote = null;
    render();
  },

  /** 外部修改或同步：換成新內容，保留目前選取的儲存格（依 row id）與 Undo */
  async applyRemote(json: string) {
    if (isEditingCell()) {
      deferredRemote = json;
      return;
    }
    const ref = await focused();
    loadRows(JSON.parse(json));
    render();
    await restoreFocus(ref);
  },

  /** 顯示設定旁檔被外部修改或同步合併 */
  async applyMeta(json: string) {
    await rerender(() => (meta = normalizeMeta(JSON.parse(json))));
  },

  async exec(command: string) {
    await commands[command]?.();
  },

  /** 改名、刪除、進背景前：結束編輯中的儲存格，讓它的 edit 先送出 */
  flush() {
    if (isEditingCell()) (document.activeElement as HTMLElement).blur();
  },

  focus() {
    grid.focus();
  },
};

declare global {
  interface Window {
    sheet: typeof api;
  }
}
window.sheet = api;
post({ type: "ready" });
