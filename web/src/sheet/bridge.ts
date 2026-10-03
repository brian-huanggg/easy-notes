// JS → Swift 訊息。打字不送訊息：edit 只在儲存格編輯結束時送出（貼上、清除也是一次）。
export type Op =
  | { op: "set"; row: number; col: number; value: string }
  | { op: "insertRows"; before: number | null; rows: { id: number; cells: string[] }[] }
  | { op: "deleteRows"; rows: number[] }
  | { op: "insertColumn"; at: number }
  | { op: "deleteColumn"; at: number }
  | { op: "order"; rows: number[] };

/** 顯示設定（`.csv.meta.json`）；`columns` 比欄數少時，其餘欄位是預設值 */
export interface Meta {
  version: number;
  columns: { width?: number | null }[];
  frozenColumns: number;
  headerRow: boolean;
}

// ops 與 meta 以 JSON 字串送出：Swift 用 JSONDecoder 解碼（避免 NSNumber 的整數 / 浮點轉換）
export type Outgoing = { type: "ready" } | { type: "edit"; ops: string } | { type: "meta"; meta: string };

export function postEdit(ops: Op[]) {
  post({ type: "edit", ops: JSON.stringify(ops) });
}

export function postMeta(meta: Meta) {
  post({ type: "meta", meta: JSON.stringify(meta) });
}

// `window.webkit` 的型別由 markdown/bridge.ts 宣告（訊息型別不同），這裡自己轉型
type WebKit = { messageHandlers?: { bridge?: { postMessage(msg: Outgoing): void } } };

export function post(msg: Outgoing) {
  const handler = (window as unknown as { webkit?: WebKit }).webkit?.messageHandlers?.bridge;
  if (handler) handler.postMessage(msg);
  else console.log("[bridge]", msg);
}
