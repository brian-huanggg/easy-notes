// frontmatter 的頂層欄位（屬性）：讀成型別化的值，寫回時只替換那個欄位的行，其餘行逐位元組保留。
// 只認識屬性面板用得到的形式：純量、`[a, b]`、下一行起的 `- a` 清單；巢狀結構與多行字串當作 raw，
// 面板只顯示、不改寫（要改就編輯原始 YAML）。規則與 Swift 端 KindMarkdown/Frontmatter.swift 相容。
import { EditorState, Text } from "@codemirror/state";
import { lines as textLines } from "./lineBreak";

export type PropValue =
  | { type: "text"; value: string }
  | { type: "list"; items: string[] }
  | { type: "checkbox"; value: boolean }
  | { type: "date"; value: string }
  | { type: "raw"; value: string };

export type PropType = PropValue["type"];

export interface Entry {
  key: string;
  /// 欄位在 frontmatter 各行中的範圍 [start, end)
  start: number;
  end: number;
  value: PropValue;
  /// 清單原本是 `[a, b]` 寫法
  flow?: boolean;
  /// 區塊清單每一項 `-` 前面的縮排
  indent?: string;
}

// 這些欄位一律當清單（Obsidian 的慣例），`tags:` 空白或單一值也是
const LIST_KEYS = new Set(["tags", "aliases", "cssclasses"]);

const KEY_LINE = /^([^\s#\-].*?)\s*:(?=\s|$)(.*)$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

function unquote(value: string): string {
  for (const q of ['"', "'"]) {
    if (value.length >= 2 && value.startsWith(q) && value.endsWith(q)) {
      const inner = value.slice(1, -1);
      if (q === '"') {
        try {
          return JSON.parse(value);
        } catch {
          return inner;
        }
      }
      return inner.replace(/''/g, "'");
    }
  }
  return value;
}

// 冒號後面的值，去掉行尾註解（不在引號內的 ` #`）
function scalarPart(rest: string): string {
  let value = rest.trim();
  if (!value.startsWith('"') && !value.startsWith("'")) {
    const hash = value.indexOf(" #");
    if (hash >= 0) value = value.slice(0, hash).trim();
  }
  return value;
}

function splitFlow(inner: string): string[] | null {
  if (/[\[\]{}]/.test(inner)) return null;
  const items: string[] = [];
  let current = "";
  let quote: string | null = null;
  for (const ch of inner) {
    if (quote) {
      current += ch;
      if (ch === quote) quote = null;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
    } else if (ch === ",") {
      items.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  items.push(current);
  return items.map((s) => unquote(s.trim())).filter((s) => s !== "");
}

function isContinuation(line: string): boolean {
  return line !== "" && (/^\s/.test(line) || line.startsWith("-"));
}

export function readEntries(lines: string[]): Entry[] {
  const entries: Entry[] = [];
  for (let i = 0; i < lines.length; i++) {
    const m = KEY_LINE.exec(lines[i]);
    if (!m) continue;
    const key = unquote(m[1].trim());
    let end = i + 1;
    while (end < lines.length && isContinuation(lines[end])) end++;
    const scalar = scalarPart(m[2]);
    const rest = lines.slice(i + 1, end);
    const entry: Entry = { key, start: i, end, value: { type: "text", value: "" } };
    if (rest.length) {
      const items = rest.map((l) => /^(\s*)-(?:\s+(.*))?$/.exec(l));
      if (scalar === "" && items.every(Boolean)) {
        entry.value = { type: "list", items: items.map((it) => unquote(scalarPart(it![2] ?? ""))).filter((s) => s !== "") };
        entry.indent = items[0]![1];
      } else {
        entry.value = { type: "raw", value: [m[2].trim(), ...rest].join("\n").trim() };
      }
    } else if (scalar.startsWith("[") && scalar.endsWith("]")) {
      const items = splitFlow(scalar.slice(1, -1));
      entry.value = items ? { type: "list", items } : { type: "raw", value: scalar };
      entry.flow = true;
    } else if (/^[{|>&*!]/.test(scalar)) {
      entry.value = { type: "raw", value: scalar };
    } else if (/^(true|false)$/i.test(scalar)) {
      entry.value = { type: "checkbox", value: scalar.toLowerCase() === "true" };
    } else if (DATE.test(scalar)) {
      entry.value = { type: "date", value: scalar };
    } else if (LIST_KEYS.has(key.toLowerCase())) {
      const value = unquote(scalar);
      entry.value = { type: "list", items: value ? [value] : [] };
    } else {
      entry.value = { type: "text", value: unquote(scalar) };
    }
    entries.push(entry);
    i = end - 1;
  }
  return entries;
}

// 寫成 YAML 純量：一般文字直接寫；含特殊字元、或看起來像布林 / 數字 / 日期 / null 時用雙引號，讀回來仍是文字
export function yamlScalar(value: string, flow = false): string {
  const plain = /^[^\s\-?:,\[\]{}#&*!|>'"%@`][^\n]*$/.test(value) && value === value.trim() && !/: | #/.test(value) && !value.endsWith(":");
  const special = flow ? /[,\[\]{}]/.test(value) : false;
  const ambiguous = /^(true|false|yes|no|on|off|null|~)$/i.test(value) || /^[-+]?(\d[\d_]*(\.\d*)?|\.\d+)([eE][-+]?\d+)?$/.test(value) || DATE.test(value);
  return plain && !special && !ambiguous ? value : JSON.stringify(value);
}

function yamlKey(key: string): string {
  return /^[^\s\-?:,\[\]{}#&*!|>'"%@`][^:#\n]*$/.test(key) && key === key.trim() ? key : JSON.stringify(key);
}

export function serializeEntry(key: string, value: PropValue, previous?: Entry): string[] {
  const k = yamlKey(key);
  switch (value.type) {
    case "text":
      return [value.value === "" ? `${k}:` : `${k}: ${yamlScalar(value.value)}`];
    case "date":
      return [value.value === "" ? `${k}:` : `${k}: ${DATE.test(value.value) ? value.value : yamlScalar(value.value)}`];
    case "checkbox":
      return [`${k}: ${value.value}`];
    case "raw":
      return previous ? [] : [`${k}: ${value.value}`];
    case "list":
      if (value.items.length === 0) return [`${k}: []`];
      if (previous?.flow) return [`${k}: [${value.items.map((s) => yamlScalar(s, true)).join(", ")}]`];
      return [`${k}:`, ...value.items.map((s) => `${previous?.indent ?? "  "}- ${yamlScalar(s)}`)];
  }
}

// 設定（value 非 null）或移除欄位；不存在時加在最後。raw 值不改寫
export function setEntry(lines: string[], key: string, value: PropValue | null): string[] {
  const entry = readEntries(lines).find((e) => e.key === key);
  if (!entry) return value === null ? lines : [...lines, ...serializeEntry(key, value)];
  if (value?.type === "raw") return lines;
  const replacement = value === null ? [] : serializeEntry(key, value, entry);
  return [...lines.slice(0, entry.start), ...replacement, ...lines.slice(entry.end)];
}

// 改名：只替換那一行冒號前的部分
export function renameEntry(lines: string[], from: string, to: string): string[] {
  const entries = readEntries(lines);
  const entry = entries.find((e) => e.key === from);
  if (!entry || !to || entries.some((e) => e.key === to)) return lines;
  const line = lines[entry.start];
  const colon = KEY_LINE.exec(line)![1].length;
  const out = lines.slice();
  out[entry.start] = yamlKey(to) + line.slice(colon);
  return out;
}

// 換型別時保留內容
export function convertValue(value: PropValue, type: PropType): PropValue {
  const text = value.type === "list" ? value.items.join(", ") : value.type === "checkbox" ? String(value.value) : value.value;
  switch (type) {
    case "text": return { type, value: text };
    case "list": return { type, items: value.type === "list" ? value.items : text.split(",").map((s) => s.trim()).filter(Boolean) };
    case "checkbox": return { type, value: value.type === "checkbox" ? value.value : /^(true|yes|on|1)$/i.test(text) };
    case "date": return { type, value: DATE.test(text) ? text : "" };
    case "raw": return value;
  }
}

// MARK: 文件中的 frontmatter

// frontmatter 的範圍：第一行開頭到結尾 `---` 那一行的行尾；沒有時回傳 null。
// 判斷規則與 Swift 端 Frontmatter.swift 一致：第一行是 `---`，之後第一個獨占一行的 `---` 結束
export function frontmatterRange(state: EditorState): { from: number; to: number } | null {
  const doc = state.doc;
  if (doc.lines < 2 || doc.line(1).text !== "---") return null;
  for (let n = 2; n <= doc.lines; n++) {
    if (doc.line(n).text === "---") return { from: 0, to: doc.line(n).to };
  }
  return null;
}

// 兩條 `---` 之間的各行
export function frontmatterLines(state: EditorState, range = frontmatterRange(state)): string[] {
  if (!range) return [];
  const from = state.doc.line(1).to + 1;
  const to = state.doc.lineAt(range.to).from - 1;
  return to > from ? state.doc.sliceString(from, to).split("\n") : [];
}

// 以各行為單位修改 frontmatter。沒有 frontmatter 時新增一個；改完變空就整個刪掉，
// 讓「設定再移除」回到原本的位元組。沒有改變時回傳 null
export function frontmatterEdit(state: EditorState, edit: (lines: string[]) => string[]): { from: number; to: number; insert: Text } | null {
  const range = frontmatterRange(state);
  const lines = frontmatterLines(state, range);
  const next = edit(lines);
  if (next.length === lines.length && next.every((l, i) => l === lines[i]) && (range || next.length === 0)) return null;
  const to = range ? Math.min(range.to + 1, state.doc.length) : 0;
  return { from: 0, to, insert: textLines(next.length ? `---\n${next.join("\n")}\n---\n` : "") };
}
