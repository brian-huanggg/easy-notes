// GFM 表格的解析與寫回（純函式，不碰 DOM；tableWidget.ts 用它）。
// 改一格只替換那一格的文字，其餘位元組不變；新增 / 刪除列欄、對齊才重寫整個表格。
// 格內是原始 md（粗體、連結等照原樣），`|` 寫成 `\|`。

export type Align = "left" | "center" | "right" | null;

export interface Cell {
  /// 格內文字（已去掉前後空白，`\|` 還原成 `|`）
  text: string;
  /// 格內原始文字在該行的範圍（去掉前後空白）
  from: number;
  to: number;
  /// 兩條 `|` 之間的範圍（含空白）
  innerFrom: number;
  innerTo: number;
}

export interface TableModel {
  header: string[];
  align: Align[];
  rows: string[][];
}

// 依未跳脫的 `|` 切開一行。開頭、結尾的 `|` 可省略（GFM）
export function splitRow(line: string): Cell[] {
  const pipes: number[] = [];
  for (let i = 0; i < line.length; i++) {
    if (line[i] === "\\") i++;
    else if (line[i] === "|") pipes.push(i);
  }
  const first = line.length - line.trimStart().length;
  const last = line.trimEnd().length - 1;
  const bounds = pipes.slice();
  if (bounds[0] !== first) bounds.unshift(-1);
  if (bounds.length < 2 || bounds[bounds.length - 1] !== last) bounds.push(line.length);
  const cells: Cell[] = [];
  for (let i = 0; i + 1 < bounds.length; i++) {
    const innerFrom = bounds[i] + 1;
    const innerTo = bounds[i + 1];
    let from = innerFrom;
    let to = innerTo;
    while (from < to && /\s/.test(line[from])) from++;
    while (to > from && /\s/.test(line[to - 1])) to--;
    cells.push({ text: unescapeCell(line.slice(from, to)), from, to, innerFrom, innerTo });
  }
  return cells;
}

export function unescapeCell(raw: string): string {
  return raw.replace(/\\\|/g, "|");
}

export function escapeCell(text: string): string {
  // 格子只有一行；換行改成空白
  return text.replace(/\r?\n/g, " ").replace(/(?<!\\)\|/g, "\\|");
}

const DELIMITER_CELL = /^:?-+:?$/;

export function isDelimiterRow(line: string): boolean {
  const cells = splitRow(line);
  return cells.length > 0 && cells.every((c) => DELIMITER_CELL.test(c.text.replace(/\s/g, "")));
}

function alignOf(cell: string): Align {
  const c = cell.replace(/\s/g, "");
  const left = c.startsWith(":");
  const right = c.endsWith(":");
  return left && right ? "center" : right ? "right" : left ? "left" : null;
}

// 表格的各行（含分隔列）→ 模型；不是表格時回傳 null
export function parseTable(lines: string[]): TableModel | null {
  if (lines.length < 2 || !isDelimiterRow(lines[1])) return null;
  const header = splitRow(lines[0]).map((c) => c.text);
  const align = splitRow(lines[1]).map((c) => alignOf(c.text));
  const width = header.length;
  const fit = <T>(cells: T[], fill: T) => (cells.length >= width ? cells.slice(0, width) : [...cells, ...Array(width - cells.length).fill(fill)]);
  return {
    header,
    align: fit(align, null),
    rows: lines.slice(2).map((line) => fit(splitRow(line).map((c) => c.text), "")),
  };
}

function delimiter(align: Align): string {
  return align === "center" ? ":---:" : align === "right" ? "---:" : align === "left" ? ":---" : "---";
}

function rowText(cells: string[]): string {
  return "| " + cells.map(escapeCell).join(" | ") + " |";
}

export function serializeTable(model: TableModel): string[] {
  return [rowText(model.header), "| " + model.align.map(delimiter).join(" | ") + " |", ...model.rows.map(rowText)];
}

// 表格第 row 列（0 = 標題列，1… = 內容列）在原始行中的索引（跳過分隔列）
export function sourceLineIndex(row: number): number {
  return row === 0 ? 0 : row + 1;
}

// 改一格：回傳該行內要替換的範圍。格子不存在（該列欄數不足）時補上缺的格子
export function cellChange(line: string, col: number, text: string): { from: number; to: number; insert: string } {
  const cells = splitRow(line);
  const value = escapeCell(text);
  if (col < cells.length) {
    const cell = cells[col];
    // 空格（`|  |`）：連同兩側空白一起換成 ` 文字 `
    if (cell.from === cell.to) return value ? { from: cell.innerFrom, to: cell.innerTo, insert: ` ${value} ` } : { from: cell.from, to: cell.to, insert: "" };
    return { from: cell.from, to: cell.to, insert: value };
  }
  // 補格子：接在最後一個 `|` 後面
  const trimmed = line.trimEnd();
  const hasEnd = trimmed.endsWith("|") && !trimmed.endsWith("\\|");
  const missing = Array(col - cells.length).fill(" ");
  const insert = (hasEnd ? "" : " |") + missing.map((c) => ` ${c} |`).join("") + ` ${value || " "} |`;
  return { from: trimmed.length, to: line.length, insert };
}

export function insertRow(model: TableModel, at: number): TableModel {
  const rows = model.rows.slice();
  rows.splice(at, 0, model.header.map(() => ""));
  return { ...model, rows };
}

export function deleteRow(model: TableModel, at: number): TableModel {
  return { ...model, rows: model.rows.filter((_, i) => i !== at) };
}

export function insertColumn(model: TableModel, at: number, name = ""): TableModel {
  const put = <T>(cells: T[], value: T) => [...cells.slice(0, at), value, ...cells.slice(at)];
  return { header: put(model.header, name), align: put(model.align, null as Align), rows: model.rows.map((r) => put(r, "")) };
}

export function deleteColumn(model: TableModel, at: number): TableModel {
  if (model.header.length <= 1) return model;
  const drop = <T>(cells: T[]) => cells.filter((_, i) => i !== at);
  return { header: drop(model.header), align: drop(model.align), rows: model.rows.map(drop) };
}

export function setAlign(model: TableModel, col: number, align: Align): TableModel {
  return { ...model, align: model.align.map((a, i) => (i === col ? align : a)) };
}

export function moveRow(model: TableModel, from: number, to: number): TableModel {
  if (to < 0 || to >= model.rows.length) return model;
  const rows = model.rows.slice();
  const [row] = rows.splice(from, 1);
  rows.splice(to, 0, row);
  return { ...model, rows };
}

export function moveColumn(model: TableModel, from: number, to: number): TableModel {
  if (to < 0 || to >= model.header.length) return model;
  const move = <T>(cells: T[]) => {
    const out = cells.slice();
    const [c] = out.splice(from, 1);
    out.splice(to, 0, c);
    return out;
  };
  return { header: move(model.header), align: move(model.align), rows: model.rows.map(move) };
}
